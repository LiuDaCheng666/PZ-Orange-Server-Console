param()

$ErrorActionPreference = "Stop"
$projectRoot = $PSScriptRoot
$testRoot = Join-Path $env:TEMP ("PZAIKnowledgePipeline-" + [guid]::NewGuid().ToString("N"))
$knowledgeRoot = Join-Path $testRoot "服务器信息库"
$script:root = $projectRoot
$script:utf8 = [Text.UTF8Encoding]::new($false)

try {
    New-Item -ItemType Directory -Path $knowledgeRoot -Force | Out-Null
    $profilesDocument = Get-Content -LiteralPath (Join-Path $projectRoot "servers.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:serverProfiles = if ($profilesDocument.servers) { @($profilesDocument.servers) } else { @($profilesDocument) }
    $production = $serverProfiles | Where-Object { [string]$_.id -ceq "production" } | Select-Object -First 1
    if (-not $production) { throw "Production test profile is unavailable." }

    . (Join-Path $projectRoot "PZ-AIBridge.ps1")
    $script:aiKnowledgeRoot = $knowledgeRoot
    $script:aiLogPath = Join-Path $testRoot "ai-test.log"
    $script:aiConfig = [pscustomobject]@{
        enabled = $false
        provider = "openai-chat"
        authMode = "bearer"
        apiUrl = "https://example.invalid"
        model = "reasoning-test-model"
        requestTimeoutSeconds = 60
        serverIds = @("production")
    }
    $script:aiApiKey = "unit-test-key"
    $script:aiKnowledgeBuildState = New-AIKnowledgeBuildState

    Set-Item -LiteralPath "Function:\script:New-AIKnowledgeHttpCall" -Value {
        param($Chunk, [string]$Model)
        return [pscustomobject]@{
            chunk = $Chunk
            model = $Model
            client = $null
            handler = $null
            content = $null
            task = [Threading.Tasks.Task]::FromResult([object]$null)
            startedAt = Get-Date
        }
    }

    $started = Start-AIKnowledgeBuild -Body ([pscustomobject]@{ serverId = "production"; model = "reasoning-test-model" })
    if (-not $started.active -or $started.status -ne "generating" -or $started.totalChunks -lt 1) {
        throw "Knowledge build pipeline did not enter the provider phase."
    }
    if ($started.sandboxFields -lt 1 -or $started.enabledMods -lt 1 -or $started.inputCharacters -lt 1000) {
        throw "Knowledge build pipeline did not preserve local source statistics."
    }
    if (@($script:aiKnowledgeBuildState.allowedPaths).Count -lt $started.sandboxFields) {
        throw "Knowledge build did not preserve the global SandboxVars validation set."
    }
    $globalAllowedPathCount = @($script:aiKnowledgeBuildState.allowedPaths).Count
    $temporaryRoot = [string]$script:aiKnowledgeBuildState.temporaryRoot
    if (-not (Test-Path -LiteralPath $temporaryRoot -PathType Container)) {
        throw "Knowledge build staging directory is missing."
    }
    $script:aiKnowledgeBuildState.completedChunks = 1
    $enhancedRoot = Join-Path ([string]$script:aiKnowledgeBuildState.generatedRoot) "AI增强"
    [IO.File]::WriteAllText((Join-Path $enhancedRoot "01-模型增强.md"), "# test`r`n", $script:utf8)
    Fail-AIKnowledgeBuild -Message "simulated provider failure"
    $failed = Get-AIKnowledgeBuildStatus
    if (-not $failed.resumable -or -not (Test-Path -LiteralPath $temporaryRoot -PathType Container)) {
        throw "Failed build did not preserve its resumable staging directory."
    }
    $resumed = Start-AIKnowledgeBuild -Body ([pscustomobject]@{ serverId = "production"; model = "reasoning-test-model" })
    if (-not $resumed.active -or $resumed.completedChunks -ne 1 -or [string]$script:aiKnowledgeBuildState.temporaryRoot -cne $temporaryRoot) {
        throw "Knowledge build did not resume from the preserved chunk."
    }
    $cancelled = Stop-AIKnowledgeBuild
    if ($cancelled.status -ne "cancelled" -or $cancelled.active -or (Test-Path -LiteralPath $temporaryRoot)) {
        throw "Cancelling the knowledge build did not clean the isolated staging directory."
    }

    [pscustomobject]@{
        ok = $true
        statusBeforeCancel = $started.status
        resumableAfterFailure = $failed.resumable
        resumedCompletedChunks = $resumed.completedChunks
        chunks = $started.totalChunks
        sourceFiles = $started.sourceFiles
        inputCharacters = $started.inputCharacters
        sandboxFields = $started.sandboxFields
        globallyAllowedPaths = $globalAllowedPathCount
        enabledMods = $started.enabledMods
        statusAfterCancel = $cancelled.status
        stagingRemoved = -not (Test-Path -LiteralPath $temporaryRoot)
    } | ConvertTo-Json
}
finally {
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $resolvedTempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if ($resolvedTestRoot.StartsWith($resolvedTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
