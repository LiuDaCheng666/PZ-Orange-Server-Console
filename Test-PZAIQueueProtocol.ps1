$ErrorActionPreference = "Stop"
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$bridgeRoot = $PSScriptRoot
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("pzai-queue-protocol-" +
    [guid]::NewGuid().ToString("N"))

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Read-EnvelopePayload {
    param([string]$Line)
    $envelope = $Line | ConvertFrom-Json
    Assert-True ($envelope.schema -eq "pzai.agent-response-record/2") "JSONL schema mismatch."
    Assert-True ($envelope.encoding -eq "base64") "JSONL encoding mismatch."
    return $utf8.GetString([Convert]::FromBase64String([string]$envelope.payload))
}

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    . (Join-Path $bridgeRoot "PZAIQueueProtocol.ps1")

    $legacyPath = Join-Path $tempRoot "PZAI-agent-response-queue.txt"
    [IO.File]::WriteAllText($legacyPath, "already-consumed`n待迁移%`t🙂`nunfinished", $utf8)
    [IO.File]::WriteAllText((Join-Path $tempRoot "PZAI-agent-response-state.ini"),
        "cursor=1`n", $utf8)

    $manifest = Initialize-PZAIResponseQueue -LuaDir $tempRoot
    Assert-True ($manifest.generation -eq 1) "Initial generation must be 1."
    Assert-True ($manifest.publishedLines -eq 1) "Only one complete unconsumed v1 row should migrate."
    Assert-True ($manifest.legacyBaseCursor -eq 1) "Legacy migration base cursor mismatch."
    $generation1Path = Join-Path $tempRoot $manifest.filename
    $migrated = @(Get-Content -LiteralPath $generation1Path -Encoding UTF8)
    Assert-True ($migrated.Count -eq 1) "Migrated queue line count mismatch."
    Assert-True ((Read-EnvelopePayload $migrated[0]) -eq "待迁移%`t🙂") `
        "v1 migration changed UTF-8 or delimiters."

    $special = "中文%`t字段🙂"
    $manifest = Write-PZAIResponseQueueLine -LuaDir $tempRoot -Payload $special
    $lines = @(Get-Content -LiteralPath $generation1Path -Encoding UTF8)
    Assert-True ($manifest.publishedLines -eq 2) "Special record was not published."
    Assert-True ((Read-EnvelopePayload $lines[1]) -eq $special) "Special record did not round-trip."

    $maximumPayload = "x" * 16384
    $manifest = Write-PZAIResponseQueueLine -LuaDir $tempRoot -Payload $maximumPayload
    $lines = @(Get-Content -LiteralPath $generation1Path -Encoding UTF8)
    Assert-True ((Read-EnvelopePayload $lines[-1]) -eq $maximumPayload) `
        "16 KiB payload did not round-trip."
    $oversizedRejected = $false
    try { [void](Write-PZAIResponseQueueLine -LuaDir $tempRoot -Payload ("x" * 16385)) }
    catch { $oversizedRejected = $true }
    Assert-True $oversizedRejected "Payload above 16 KiB was accepted."

    $publishedBeforePartial = $manifest.publishedLines
    [IO.File]::AppendAllText($generation1Path, '{"schema":"partial', $utf8)
    $manifest = Initialize-PZAIResponseQueue -LuaDir $tempRoot
    Assert-True ($manifest.publishedLines -eq $publishedBeforePartial) `
        "A half-written JSONL record became published."
    $bytesAfterRecovery = [IO.File]::ReadAllBytes($generation1Path)
    Assert-True ($bytesAfterRecovery[-1] -eq 10) "Half-written tail was not truncated on recovery."

    $recoveredPayload = "flushed-before-manifest"
    $recoveredLine = ConvertTo-PZAIQueueEnvelope -Payload $recoveredPayload
    $stream = [IO.FileStream]::new($generation1Path, [IO.FileMode]::Append,
        [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        $bytes = $utf8.GetBytes($recoveredLine + "`n")
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
    $manifest = Initialize-PZAIResponseQueue -LuaDir $tempRoot
    Assert-True ($manifest.publishedLines -eq ($publishedBeforePartial + 1)) `
        "A fully flushed crash-boundary record was not recovered."
    $sameManifest = Initialize-PZAIResponseQueue -LuaDir $tempRoot
    Assert-True ($sameManifest.publishedLines -eq $manifest.publishedLines) `
        "Repeated initialization republished a record."

    $ackText = "schema=pzai.agent-response-ack/2`ngeneration=$($manifest.generation)`n" +
        "filename=$($manifest.filename)`ncursor=$($manifest.publishedLines)`n"
    Write-PZAIAtomicUtf8 -Path (Join-Path $tempRoot "PZAI-agent-response-ack.ini") `
        -Text $ackText
    $script:PZAIQueueMaxLines = 1
    $rotated = Write-PZAIResponseQueueLine -LuaDir $tempRoot -Payload "new-generation"
    Assert-True ($rotated.generation -eq 2) "Acknowledged full queue did not rotate."
    Assert-True ($rotated.publishedLines -eq 1) "New generation publication count mismatch."
    Assert-True (Test-Path -LiteralPath $generation1Path -PathType Leaf) `
        "Previous generation was removed before the required retention window."

    $manifestValues = Read-PZAIIni -Path (Join-Path $tempRoot "PZAI-agent-response-manifest.ini")
    foreach ($key in @("generation", "filename", "publishedLines")) {
        Assert-True ($manifestValues.ContainsKey($key)) "Manifest is missing $key."
    }
    Assert-True (@(Get-ChildItem -LiteralPath $tempRoot -Filter '*.tmp').Count -eq 0) `
        "Atomic publication left temporary files behind."

    $panelDataRoot = Join-Path $tempRoot "panel-server"
    $panelLuaRoot = Join-Path $panelDataRoot "Lua"
    New-Item -ItemType Directory -Path $panelLuaRoot -Force | Out-Null
    $tokens = $null
    $parseErrors = $null
    $bridgeAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot "PZ-AIBridge.ps1"), [ref]$tokens, [ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) "PZ-AIBridge.ps1 did not parse."
    $statusFunctionAst = @($bridgeAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq "Get-AIBridgeStatus"
    }, $true))[0]
    Assert-True ($null -ne $statusFunctionAst) "Bridge status function was not found."
    Assert-True ($statusFunctionAst.Extent.Text -match
        'requestProtocol\s*=\s*"managed-response-queue/2"') `
        "Bridge status does not advertise managed response queue v2."
    foreach ($name in @("ConvertTo-AIQueueText", "Write-AIManagedRecord")) {
        $functionAst = @($bridgeAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq $name
        }, $true))[0]
        Assert-True ($null -ne $functionAst) "Bridge function was not found: $name"
        Invoke-Expression $functionAst.Extent.Text
    }
    $serverProfiles = @([pscustomobject]@{ id = "server-1"; dataRoot = $panelDataRoot })
    $script:aiConfig = [pscustomobject]@{ provider = "test-provider"; model = "test-model" }
    $request = [pscustomobject]@{
        serverId = "server-1"; sessionId = "session-1"; requestId = "request-1"
        username = "测试玩家"; attempts = 1
    }
    $recordId = Write-AIManagedRecord -Request $request -Kind response -StartedMs 100 -CompletedMs 120 -LatencyMs 20 -Code agent_answered -Title "标题%" -Message "中文%字段🙂 第二行"
    $panelManifest = Get-PZAIQueueManifest -LuaDir $panelLuaRoot
    Assert-True ($panelManifest.publishedLines -eq 1) "Write-AIManagedRecord did not publish one v2 record."
    $panelLine = Get-Content -LiteralPath (Join-Path $panelLuaRoot $panelManifest.filename) -Encoding UTF8
    $panelFields = (Read-EnvelopePayload $panelLine) -split "\t"
    Assert-True ($panelFields.Count -eq 17 -and $panelFields[1] -eq $recordId -and $panelFields[2] -eq "response" -and $panelFields[5] -eq "测试玩家" -and $panelFields[14] -eq "标题%25" -and $panelFields[15] -eq "中文%25字段🙂 第二行") "Write-AIManagedRecord changed identity or escaped response content."
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $panelLuaRoot "PZAI-agent-response-queue.txt"))) "Write-AIManagedRecord unexpectedly appended to the legacy queue."

    Write-Host "PASS: queue v2 migration, UTF-8, 16 KiB, crash recovery, rotation, and panel integration"
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
