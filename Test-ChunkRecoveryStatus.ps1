param()

$ErrorActionPreference = "Stop"
$projectRoot = $PSScriptRoot
$testRoot = Join-Path $env:TEMP ("PZChunkRecoveryStatus-" + [guid]::NewGuid().ToString("N"))
$script:chunkRecoveryRoot = Join-Path $testRoot "chunk-recovery"
$script:utf8 = [Text.UTF8Encoding]::new($false)

function Import-PanelFunction {
    param([string]$Name)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot "PZ-ControlPanel.ps1"), [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "Panel script does not parse." }
    $functionAst = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name
    }, $true)
    if (-not $functionAst) { throw "Function not found: $Name" }
    Set-Item -LiteralPath "Function:\script:$Name" -Value $functionAst.Body.GetScriptBlock()
}

foreach ($name in @("Get-ChunkRecoveryPaths", "Read-MapResetJson", "Write-MapResetJson", "Complete-ChunkRecoveryStatus")) {
    Import-PanelFunction -Name $name
}

try {
    $profile = [pscustomobject]@{ id = "legacy"; dataRoot = $testRoot }
    $paths = Get-ChunkRecoveryPaths -Profile $profile
    $operationRoot = Join-Path $paths.operationsRoot "legacy-operation"
    New-Item -ItemType Directory -Path $operationRoot -Force | Out-Null
    $exitCodePath = Join-Path $operationRoot "exit-code.txt"
    $resultPath = Join-Path $operationRoot "result.json"
    $errorPath = Join-Path $operationRoot "stderr.log"
    [IO.File]::WriteAllText($exitCodePath, "0", $utf8)
    [IO.File]::WriteAllText($resultPath, '{"mode":"restore","restoredChunkCount":1}', $utf8)

    $legacyStatus = [ordered]@{
        operationId = "legacy-operation"
        serverId = "legacy"
        mode = "restore"
        state = "running"
        pid = 2147483647
        startedAt = (Get-Date).AddMinutes(-1).ToString("o")
        finishedAt = $null
        operationRoot = $operationRoot
        resultPath = $resultPath
        errorPath = $errorPath
        exitCodePath = $exitCodePath
        progressPath = (Join-Path $operationRoot "progress.json")
        result = $null
        error = $null
    }
    Write-MapResetJson -Path $paths.statusPath -Value $legacyStatus

    $completed = Complete-ChunkRecoveryStatus -Profile $profile
    if ([string]$completed.state -cne "completed") { throw "Legacy operation did not complete." }
    if (-not $completed.PSObject.Properties["exitCode"] -or [int]$completed.exitCode -ne 0) { throw "Legacy status did not gain exitCode." }
    if (-not $completed.finishedAt -or [int]$completed.result.restoredChunkCount -ne 1) { throw "Legacy result was not finalized." }

    $persisted = Get-Content -LiteralPath $paths.statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$persisted.state -cne "completed" -or [int]$persisted.exitCode -ne 0) { throw "Completed status was not persisted." }

    [pscustomobject]@{
        ok = $true
        legacyStatusCompatible = $true
        state = [string]$persisted.state
        exitCode = [int]$persisted.exitCode
        restoredChunkCount = [int]$persisted.result.restoredChunkCount
    } | ConvertTo-Json
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
