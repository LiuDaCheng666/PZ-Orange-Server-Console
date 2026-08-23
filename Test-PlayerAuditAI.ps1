param(
    [switch]$Live,
    [string]$ServerId,
    [string]$SteamId,
    [string]$Username
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$utf8 = [Text.UTF8Encoding]::new($false)
$playerAuditSopPath = Join-Path $root "PLAYER-AUDIT-SOP.zh-CN.md"
$serversPath = Join-Path $root "servers.json"
$serverProfiles = if (Test-Path -LiteralPath $serversPath -PathType Leaf) {
    @((Get-Content -LiteralPath $serversPath -Raw -Encoding UTF8 | ConvertFrom-Json).servers)
} else { @() }

. (Join-Path $root "PZ-AIBridge.ps1")
$script:aiConfig = Read-AIConfig
$script:aiApiKey = Unprotect-AIApiKey

$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $root "PZ-ControlPanel.ps1"), [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -gt 0) { throw "PZ-ControlPanel.ps1 has syntax errors." }
foreach ($name in @("New-PlayerAuditAIHttpCall", "ConvertTo-PlayerAuditStringList", "ConvertFrom-PlayerAuditAIResponse")) {
    $definition = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true) | Select-Object -First 1
    if (-not $definition) { throw "Missing function: $name" }
    Invoke-Expression $definition.Extent.Text
}

$sampleText = '{"verdict":"\u9700\u8981\u89c2\u5bdf","confidence":72,"summary":"One weak signal requires review.","findings":[{"severity":"warning","title":"Lua checksum mismatch","evidence":["Logs/example_DebugLog-server.txt:12"],"interpretation":"This signal cannot establish cheating by itself."}],"limitations":["Mock evidence only."],"recommendedActions":["Review client and server mod versions manually."]}'
$sampleProviderResponse = switch ([string]$script:aiConfig.provider) {
    "openai-responses" { @{ output_text = $sampleText } | ConvertTo-Json -Depth 8 -Compress }
    "openai-chat" { @{ choices = @(@{ message = @{ content = $sampleText } }) } | ConvertTo-Json -Depth 8 -Compress }
    default { @{ content = @(@{ type = "text"; text = $sampleText }) } | ConvertTo-Json -Depth 8 -Compress }
}
$validated = ConvertFrom-PlayerAuditAIResponse -Json $sampleProviderResponse -Provider ([string]$script:aiConfig.provider)
if ($validated.riskLevel -ne "warning" -or @($validated.findings).Count -ne 1) {
    throw "AI audit response validator failed."
}

$speedOnlyText = '{"verdict":"\u8bc1\u636e\u786e\u51ff","confidence":99,"summary":"Repeated Speed cooldown kicks prove cheating.","findings":[{"severity":"critical","title":"Speed cooldown repeated","evidence":["Logs/example_DebugLog-server.txt:12"],"interpretation":"Many speed records were logged with action=Kick."}],"limitations":[],"recommendedActions":[]}'
$speedOnlyProviderResponse = switch ([string]$script:aiConfig.provider) {
    "openai-responses" { @{ output_text = $speedOnlyText } | ConvertTo-Json -Depth 8 -Compress }
    "openai-chat" { @{ choices = @(@{ message = @{ content = $speedOnlyText } }) } | ConvertTo-Json -Depth 8 -Compress }
    default { @{ content = @(@{ type = "text"; text = $speedOnlyText }) } | ConvertTo-Json -Depth 8 -Compress }
}
$speedOnlyValidated = ConvertFrom-PlayerAuditAIResponse -Json $speedOnlyProviderResponse -Provider ([string]$script:aiConfig.provider)
$speedOnlyFinding = @($speedOnlyValidated.findings) | Select-Object -First 1
if ($speedOnlyValidated.verdict -ne $validated.verdict -or $speedOnlyValidated.riskLevel -ne 'warning' -or $speedOnlyFinding.severity -ne 'warning' -or $speedOnlyValidated.confidence -gt 80) {
    throw 'Speed-only AI audit was not deterministically downgraded.'
}

$node = (Get-Command node.exe -ErrorAction Stop).Source
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("pz-anticheat-speed-" + [guid]::NewGuid().ToString("N"))
$fixtureData = Join-Path $fixtureRoot "data"
$fixtureRuntime = Join-Path $fixtureRoot "runtime"
$fixtureLogs = Join-Path $fixtureData "Logs"
try {
    New-Item -ItemType Directory -Path $fixtureLogs, $fixtureRuntime -Force | Out-Null
    $timestamp = Get-Date -Format "dd-MM-yy HH:mm:ss.fff"
    $speedLine = "[$timestamp] LOG  : General     , 0> Anti-cheat=`"Speed`" connection=`"LagPlayer`" reason=`"cooldown`" action=`"Kick`""
    $duplicateLine = "[$timestamp] Anti-cheat=`"PlayerUpdate`" is triggered for connection=`"DuplicatePlayer`" reason=`"update failed`" action=`"Log`""
    $protectedLine = "[$timestamp] 76561198000000002 `"CriticalPlayer`" player.onHealthCheatCurrentPlayer @ 100,200,0."
    $adminLine = "[$timestamp] 76561198000000003 `"admin`" player.onHealthCheat @ 300,400,0."
    $authorizedTime = (Get-Date).AddMilliseconds(200).ToString("dd-MM-yy HH:mm:ss.fff")
    $authorizedLine = "[$authorizedTime] 76561198000000004 `"ManagedPlayer`" player.onHealthCheatCurrentPlayer @ 300,400,0."
    $connectionLine = "[$timestamp] user `"admin`" steam-id=`"76561198000000003`" role=`"admin`" username=`"admin`" ip=`"127.0.0.1`""
    $adminProtectedLine = "[$authorizedTime] 76561198000000003 `"admin`" player.setWeight @ 300,400,0."
    $fakeAdminLine = "[$authorizedTime] 76561198000000005 `"admin-lookalike`" player.setWeight @ 500,600,0."
    $fakeAdminConnectionLine = "[$timestamp] event=`"fully-connected`" steam-id=`"76561198000000005`" role=`"user`" username=`"admin-lookalike`" ip=`"127.0.0.2`""
    [IO.File]::WriteAllText((Join-Path $fixtureLogs "21-08-26_DebugLog-server.txt"), "$speedLine`n$duplicateLine", $utf8)
    [IO.File]::WriteAllText((Join-Path $fixtureLogs "21-08-26_user.txt"), $duplicateLine, $utf8)
    [IO.File]::WriteAllText((Join-Path $fixtureLogs "21-08-26_connections.txt"), "$connectionLine`n$fakeAdminConnectionLine", $utf8)
    [IO.File]::WriteAllText((Join-Path $fixtureLogs "21-08-26_cmd.txt"), "$protectedLine`n$adminLine`n$authorizedLine`n$adminProtectedLine`n$fakeAdminLine", $utf8)

    $readerRaw = @(& $node (Join-Path $root "Read-PZAntiCheatEvents.js") $fixtureData $fixtureRuntime 24 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Anti-cheat reader fixture failed: $($readerRaw -join "`n")" }
    $readerPayload = ($readerRaw -join "`n") | ConvertFrom-Json
    $lagPlayer = @($readerPayload.players | Where-Object { @($_.usernames) -contains "LagPlayer" }) | Select-Object -First 1
    $speedEvent = @($readerPayload.events | Where-Object { $_.code -eq "Speed" }) | Select-Object -First 1
    if (-not $lagPlayer -or $lagPlayer.score -ne 0 -or $lagPlayer.actionableNativeSignals -ne 0 -or $lagPlayer.speedNoiseSignals -ne 1 -or -not $speedEvent.noiseLikely -or $speedEvent.evidenceWeight -ne "noise") {
        throw "Speed cooldown was not classified as zero-weight noise by the anti-cheat reader."
    }
    $duplicatePlayer = @($readerPayload.players | Where-Object { @($_.usernames) -contains "DuplicatePlayer" }) | Select-Object -First 1
    $criticalPlayer = @($readerPayload.players | Where-Object { $_.steamId -eq "76561198000000002" }) | Select-Object -First 1
    $criticalReason = @($criticalPlayer.reasons | Where-Object { $_.code -eq "protected-command" }) | Select-Object -First 1
    $managedPlayer = @($readerPayload.players | Where-Object { $_.steamId -eq "76561198000000004" }) | Select-Object -First 1
    $adminPlayer = @($readerPayload.players | Where-Object { $_.steamId -eq "76561198000000003" }) | Select-Object -First 1
    $fakeAdminPlayer = @($readerPayload.players | Where-Object { $_.steamId -eq "76561198000000005" }) | Select-Object -First 1
    if (-not $duplicatePlayer -or $duplicatePlayer.nativeSignals -ne 1 -or $duplicatePlayer.actionableNativeSignals -ne 1) {
        throw "The same native anti-cheat signal was counted more than once across physical logs."
    }
    if (-not $criticalPlayer -or $criticalPlayer.score -ne 80 -or $criticalReason.points -ne 80 -or
            -not @($criticalPlayer.evidenceEvents | Where-Object { $_.type -eq "protected-command" }).Count) {
        throw "Critical per-player evidence or score breakdown was not preserved."
    }
    if (-not $managedPlayer -or $managedPlayer.score -ne 0 -or $managedPlayer.protectedCalls -ne 0 -or
            $managedPlayer.authorizedAdminActions -ne 1 -or
            -not @($managedPlayer.evidenceEvents | Where-Object { $_.type -eq "authorized-admin-action" }).Count) {
        throw "Authorized admin health relay was incorrectly attributed to the target player."
    }
    if (-not $adminPlayer -or -not $adminPlayer.adminPower -or $adminPlayer.score -ne 0 -or $adminPlayer.protectedCalls -ne 0 -or
            $adminPlayer.adminCommandCalls -ne 1 -or $adminPlayer.authorizedAdminActions -ne 1 -or
            -not @($adminPlayer.evidenceEvents | Where-Object { $_.code -eq "admin-command" }).Count) {
        throw "A verified administrator command was incorrectly scored as cheating."
    }
    if (-not $fakeAdminPlayer -or $fakeAdminPlayer.adminPower -or $fakeAdminPlayer.score -ne 80 -or $fakeAdminPlayer.protectedCalls -ne 1) {
        throw "A normal player received an administrator exemption based on their username."
    }

    $evidenceRaw = @(& $node (Join-Path $root "Build-PZPlayerAuditEvidence.js") $fixtureData $fixtureRuntime "testserver" 24 "76561198000000001" "LagPlayer" 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Player evidence fixture failed: $($evidenceRaw -join "`n")" }
    $evidencePayload = ($evidenceRaw -join "`n") | ConvertFrom-Json
    $speedNoiseSample = @($evidencePayload.logs.speedNoise.samples) | Select-Object -First 1
    if ($evidencePayload.logs.speedNoise.count -ne 1 -or $evidencePayload.logs.nativeAntiCheatSummary.speedNoise -ne 1 -or @($evidencePayload.logs.nativeAntiCheat).Count -ne 0 -or $speedNoiseSample.evidenceWeight -ne "noise") {
        throw "Speed cooldown noise leaked into actionable AI evidence."
    }
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}

$result = [ordered]@{ ok = $true; validator = $true; speedGuard = $true; live = $false }
if ($Live) {
    if (-not (Test-AIProviderConfigured)) { throw "The AI provider is not configured." }
    if ([string]::IsNullOrWhiteSpace($ServerId) -or $SteamId -notmatch '^7656119\d{10}$' -or [string]::IsNullOrWhiteSpace($Username)) {
        throw "Live mode requires -ServerId, -SteamId, and -Username."
    }
    $profile = @($serverProfiles | Where-Object { [string]$_.id -eq $ServerId -or [string]$_.serverName -eq $ServerId }) | Select-Object -First 1
    if (-not $profile) { throw "Server profile not found: $ServerId" }
    $reader = Join-Path $root "Build-PZPlayerAuditEvidence.js"
    $rawEvidence = @(& $node $reader ([string]$profile.dataRoot) ([string]$profile.runtimeRoot) ([string]$profile.serverName) 24 $SteamId $Username 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Evidence builder failed: $($rawEvidence -join "`n")" }
    $evidence = ($rawEvidence -join "`n") | ConvertFrom-Json
    $call = New-PlayerAuditAIHttpCall -Evidence $evidence
    try {
        $response = $call.task.GetAwaiter().GetResult()
        $raw = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            if ($raw.Length -gt 600) { $raw = $raw.Substring(0, 600) }
            throw "AI audit endpoint returned HTTP $([int]$response.StatusCode): $raw"
        }
        $report = ConvertFrom-PlayerAuditAIResponse -Json $raw -Provider ([string]$call.provider)
        $result.live = $true
        $result.provider = [string]$call.provider
        $result.model = [string]$call.model
        $result.verdict = [string]$report.verdict
        $result.confidence = [int]$report.confidence
        $result.findings = @($report.findings).Count
    }
    finally {
        try { $call.content.Dispose() } catch { }
        try { $call.client.Dispose() } catch { }
        try { $call.handler.Dispose() } catch { }
    }
}

$result | ConvertTo-Json
