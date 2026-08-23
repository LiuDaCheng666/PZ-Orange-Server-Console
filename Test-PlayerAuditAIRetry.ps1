param()

$ErrorActionPreference = "Stop"
$projectRoot = $PSScriptRoot
$script:playerAuditAnalyses = @{}
Add-Type -AssemblyName System.Net.Http

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
    return [string]$functionAst.Extent.Text
}

function New-MockAuditCall {
    param([string]$Body, [int]$Attempt)
    $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::OK)
    $response.Content = [Net.Http.StringContent]::new($Body)
    $source = [Threading.Tasks.TaskCompletionSource[Net.Http.HttpResponseMessage]]::new()
    $source.SetResult($response)
    $handler = [Net.Http.HttpClientHandler]::new()
    return [pscustomobject]@{
        provider = "openai-responses"
        model = "test-model"
        attempt = $Attempt
        maximumTokens = $(if ($Attempt -gt 1) { 12000 } else { 8000 })
        client = [Net.Http.HttpClient]::new($handler)
        handler = $handler
        content = [Net.Http.StringContent]::new("{}")
        task = $source.Task
    }
}

$newCallSource = Import-PanelFunction -Name "New-PlayerAuditAIHttpCall"
[void](Import-PanelFunction -Name "Get-PlayerAuditAnalysisPayload")
if ($newCallSource -notmatch '12000.+8000' -or $newCallSource -notmatch 'effort\s*=\s*"low"') {
    throw "Player audit token budgets or low-reasoning policy regressed."
}

$script:retryCallCount = 0
function New-PlayerAuditAIHttpCall {
    param($Evidence, [int]$Attempt)
    $script:retryCallCount++
    return New-MockAuditCall -Body "completed" -Attempt $Attempt
}
function ConvertFrom-PlayerAuditAIResponse {
    param([string]$Json, [string]$Provider)
    if ($Json -eq "exhausted") {
        throw "incomplete: max_output_tokens"
    }
    return [pscustomobject]@{ verdict = "none"; riskLevel = "low"; confidence = 90; summary = "test-complete"; findings = @(); limitations = @(); recommendedActions = @() }
}

$id = "a" * 32
$evidence = [pscustomobject]@{
    generatedAt = (Get-Date).ToString("o")
    economy = [pscustomobject]@{ available = $true; eventCount = 0; discontinuityCount = 0 }
    logs = [pscustomobject]@{
        logSummary = [pscustomobject]@{ filesScanned = 1; categoryCounts = [pscustomobject]@{ command = 0 } }
        adminHits = @(); itemHits = @(); nativeAntiCheat = @(); speedNoise = [pscustomobject]@{ count = 0 }
        nativeAntiCheatSummary = [pscustomobject]@{ speedReview = 0 }; protectedOrBlocked = @()
        lifestyle = [pscustomobject]@{ unmatched = @() }
    }
    pzai = [pscustomobject]@{ serverSnapshots = @(); clientDeclarations = @() }
}
$script:playerAuditAnalyses[$id] = [pscustomobject]@{
    id = $id; status = "analyzing"; createdAt = (Get-Date).ToString("o"); completedAt = $null
    serverId = "test"; steamId = "76561198000000001"; username = "Tester"; hours = 24
    model = "test-model"; call = (New-MockAuditCall -Body "exhausted" -Attempt 1); evidence = $evidence
    report = $null; error = $null; attempt = 1; maximumAttempts = 2; message = "first"
}

$retryPayload = Get-PlayerAuditAnalysisPayload -Id $id
if ($retryPayload.status -ne "analyzing" -or $retryPayload.attempt -ne 2 -or $retryCallCount -ne 1) {
    throw "Output exhaustion did not start exactly one transparent retry."
}
$completedPayload = Get-PlayerAuditAnalysisPayload -Id $id
if ($completedPayload.status -ne "completed" -or $completedPayload.attempt -ne 2 -or $completedPayload.report.summary -ne "test-complete") {
    throw "Automatic retry did not produce the completed audit payload."
}

[pscustomobject]@{
    ok = $true
    initialBudget = 8000
    retryBudget = 12000
    retryCalls = $retryCallCount
    finalStatus = $completedPayload.status
} | ConvertTo-Json
