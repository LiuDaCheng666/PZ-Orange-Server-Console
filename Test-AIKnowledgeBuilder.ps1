param()

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Net.Http
$projectRoot = $PSScriptRoot
$generatedRoot = Join-Path $projectRoot "服务器信息库\自动生成"

function Import-BridgeFunction {
    param([string]$Name)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot "PZ-AIBridge.ps1"), [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "Bridge script does not parse." }
    $functionAst = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name
    }, $true)
    if (-not $functionAst) { throw "Function not found: $Name" }
    Set-Item -LiteralPath "Function:\script:$Name" -Value $functionAst.Body.GetScriptBlock()
}

foreach ($name in @("New-AIKnowledgeBuildState", "New-AIKnowledgeSourceChunks", "Assert-AIKnowledgeModelOutput", "Get-AIResponseTextRaw", "Resolve-AIKnowledgeReasoningEffort", "Resolve-AIKnowledgeBuildProvider", "Complete-AIKnowledgeBuildCall")) {
    Import-BridgeFunction -Name $name
}

$flashAutoEffort = Resolve-AIKnowledgeReasoningEffort -Requested "auto" -Model "deepseek-v4-flash" -Provider "openai-responses"
$proAutoEffort = Resolve-AIKnowledgeReasoningEffort -Requested "auto" -Model "deepseek-v4-pro" -Provider "openai-responses"
$proHighEffort = Resolve-AIKnowledgeReasoningEffort -Requested "high" -Model "deepseek-v4-pro" -Provider "openai-responses"
$proChatHighEffort = Resolve-AIKnowledgeReasoningEffort -Requested "high" -Model "deepseek-v4-pro" -Provider "openai-chat"
$explicitHighEffort = Resolve-AIKnowledgeReasoningEffort -Requested "high" -Model "gpt-5" -Provider "openai-responses"
$deepSeekHighRejected = $false
try { [void](Resolve-AIKnowledgeReasoningEffort -Requested "high" -Model "deepseek-v4-flash" -Provider "openai-responses") }
catch { $deepSeekHighRejected = $_.Exception.Message -match '只允许 Auto 或 Low' }
$chatEffort = Resolve-AIKnowledgeReasoningEffort -Requested "auto" -Model "deepseek-reasoner" -Provider "openai-chat"
if ($flashAutoEffort -ne "low" -or $proAutoEffort -ne "low" -or $proHighEffort -ne "high" -or $proChatHighEffort -ne "high" -or $explicitHighEffort -ne "high" -or -not $deepSeekHighRejected -or $chatEffort -ne "model") {
    throw "Knowledge build reasoning effort selection is invalid."
}
$officialProProvider = Resolve-AIKnowledgeBuildProvider -RequestedProvider "openai-responses" -ApiUrl "https://api.deepseek.com" -Model "deepseek-v4-pro"
$proxyProProvider = Resolve-AIKnowledgeBuildProvider -RequestedProvider "openai-responses" -ApiUrl "https://example.invalid/v1" -Model "deepseek-v4-pro"
$officialFlashProvider = Resolve-AIKnowledgeBuildProvider -RequestedProvider "openai-responses" -ApiUrl "https://api.deepseek.com" -Model "deepseek-v4-flash"
if ($officialProProvider -ne "openai-chat" -or $proxyProProvider -ne "openai-responses" -or $officialFlashProvider -ne "openai-responses") {
    throw "Knowledge build provider routing is invalid."
}

$script:aiKnowledgeBuildState = New-AIKnowledgeBuildState
$script:aiKnowledgeBuildState.model = "deepseek-v4-pro"
$script:aiKnowledgeBuildState.requestedModel = "deepseek-v4-pro"
$script:aiKnowledgeBuildState.reasoningEffort = "high"
$script:aiKnowledgeBuildState.totalChunks = 1
$script:aiKnowledgeBuildState.chunks = @([pscustomobject]@{ index = 1; labels = @("test"); text = "test"; allowedPaths = @() })
$handler = [Net.Http.HttpClientHandler]::new()
$client = [Net.Http.HttpClient]::new($handler)
$content = [Net.Http.StringContent]::new("{}")
$response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::BadRequest)
$response.Content = [Net.Http.StringContent]::new('{"error":{"message":"Codex integration with deepseek-v4-pro will be available later. Please use deepseek-v4-flash instead for now."}}')
$script:aiKnowledgeBuildCall = [pscustomobject]@{
    chunk = $script:aiKnowledgeBuildState.chunks[0]
    client = $client
    handler = $handler
    content = $content
    task = [Threading.Tasks.Task[Net.Http.HttpResponseMessage]]::FromResult($response)
}
$script:fallbackRetryStarted = $false
Set-Item -LiteralPath "Function:\script:Write-AIBridgeLog" -Value { param($Level, $Message) }
Set-Item -LiteralPath "Function:\script:Start-NextAIKnowledgeBuildCall" -Value { $script:fallbackRetryStarted = $true }
Set-Item -LiteralPath "Function:\script:Fail-AIKnowledgeBuild" -Value { param($Message, $Status) throw "Unexpected build failure: $Message" }
Complete-AIKnowledgeBuildCall
if (-not $script:fallbackRetryStarted -or $script:aiKnowledgeBuildState.model -ne "deepseek-v4-flash" -or $script:aiKnowledgeBuildState.reasoningEffort -ne "low" -or $script:aiKnowledgeBuildState.completedChunks -ne 0) {
    throw "Unavailable V4 Pro response did not retry the same chunk with Flash Low."
}
$response.Dispose()

$script:aiConfig = [pscustomobject]@{ provider = "openai-responses" }
$nestedResponse = [ordered]@{
    status = "completed"
    output_text = ""
    output = @(
        [ordered]@{ type = "reasoning"; content = @([ordered]@{ type = "reasoning_text"; text = "internal" }) }
        [ordered]@{ type = "message"; content = @([ordered]@{ type = "output_text"; text = "# DeepSeek nested response`n`nParsed correctly." }) }
    )
    usage = [ordered]@{ output_tokens = 12 }
} | ConvertTo-Json -Depth 8
$nestedText = Get-AIResponseTextRaw -Json $nestedResponse
if ($nestedText -notmatch 'Parsed correctly') { throw "Nested Responses output_text was not parsed." }

$tokenLimitDiagnosed = $false
$incompleteResponse = [ordered]@{
    status = "incomplete"
    incomplete_details = [ordered]@{ reason = "max_output_tokens" }
    output = @([ordered]@{ type = "reasoning"; content = @([ordered]@{ type = "reasoning_text"; text = "internal" }) })
    usage = [ordered]@{ output_tokens = 6000 }
} | ConvertTo-Json -Depth 8
try { [void](Get-AIResponseTextRaw -Json $incompleteResponse) }
catch { $tokenLimitDiagnosed = $_.Exception.Message -match 'token 上限耗尽' }
if (-not $tokenLimitDiagnosed) { throw "Incomplete reasoning-only response was not diagnosed." }

if (-not (Test-Path -LiteralPath $generatedRoot -PathType Container)) {
    throw "Run Build-PZServerKnowledgeBase.ps1 before this test."
}

$chunks = @(New-AIKnowledgeSourceChunks -GeneratedRoot $generatedRoot)
$sourceText = @(Get-ChildItem -LiteralPath $generatedRoot -Recurse -File -Filter "*.md" | ForEach-Object {
    Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
}) -join "`n"
$sourcePaths = @([regex]::Matches($sourceText, 'SandboxVars\.([A-Za-z][A-Za-z0-9_.-]*)') |
    ForEach-Object { $_.Groups[1].Value.TrimEnd('.') } | Select-Object -Unique)
$chunkPaths = @($chunks | ForEach-Object { @($_.allowedPaths) } | Select-Object -Unique)
$missing = @($sourcePaths | Where-Object { $_ -notin $chunkPaths })
if ($missing.Count -gt 0) { throw "Chunking lost $($missing.Count) SandboxVars paths." }

$known = [string]$sourcePaths[0]
$accepted = @"
# 字段解释

``SandboxVars.$known`` 的当前值必须引用本地权威索引。本段只补充中文同义问法和检索提示，字段单位无法确认时明确标记为待对应 Mod 文档确认，不能把默认值当成本服值。
"@
$safe = Assert-AIKnowledgeModelOutput -Text $accepted -AllowedPaths @($known)
if ([string]::IsNullOrWhiteSpace($safe)) { throw "Safe model output was rejected." }

$wildcardText = $accepted + "`n字段族 SandboxVars.BuildingCraft*、SandboxVars.lgd_antibodies_194_* 和 SandboxVars.Is... 只作为检索提示。"
$normalizedWildcard = Assert-AIKnowledgeModelOutput -Text $wildcardText -AllowedPaths @($known)
if ($normalizedWildcard -match 'SandboxVars\.(?:BuildingCraft|lgd_antibodies_194_|Is)') {
    throw "SandboxVars wildcard family was not normalized."
}

$familyPrefixText = $accepted + "`n字段族 SandboxVars.lgd_antibodies_194_ 用于归纳抗体相关设置。"
$normalizedFamilyPrefix = Assert-AIKnowledgeModelOutput -Text $familyPrefixText -AllowedPaths @(
    $known,
    "lgd_antibodies_194_general_base_growth",
    "lgd_antibodies_194_general_recovery_effect"
)
if ($normalizedFamilyPrefix -match 'SandboxVars\.lgd_antibodies_194_') {
    throw "SandboxVars family prefix was not normalized."
}

$crossChunkGroupText = $accepted + "`n配置组 SandboxVars.ZombieVirusVaccineBETA 包含疫苗 Mod 的多项设置。"
$normalizedCrossChunkGroup = Assert-AIKnowledgeModelOutput -Text $crossChunkGroupText -AllowedPaths @($sourcePaths)
if ($normalizedCrossChunkGroup -match 'SandboxVars\.ZombieVirusVaccineBETA') {
    throw "Cross-chunk SandboxVars group was not normalized against the global path set."
}

$unknownSanitized = Assert-AIKnowledgeModelOutput -Text ($accepted + "`nSandboxVars.NotInSource.Enabled 当前为 true。") -AllowedPaths @($known)
if ($unknownSanitized -match 'SandboxVars\.NotInSource\.Enabled') { throw "Invented SandboxVars path was not removed." }

$excessiveUnknownRejected = $false
$excessiveUnknownText = $accepted + "`n" + (@(1..9 | ForEach-Object { "SandboxVars.NotInSource.Field$_ 当前为 true。" }) -join "`n")
try { [void](Assert-AIKnowledgeModelOutput -Text $excessiveUnknownText -AllowedPaths @($known)) }
catch { $excessiveUnknownRejected = $_.Exception.Message -match '过多输入中不存在' }
if (-not $excessiveUnknownRejected) { throw "Excessive invented SandboxVars paths were accepted." }

$secretRejected = $false
try {
    [void](Assert-AIKnowledgeModelOutput -Text ($accepted + "`napi_key=example-placeholder-value") -AllowedPaths @($known))
}
catch { $secretRejected = $true }
if (-not $secretRejected) { throw "Credential-like output was accepted." }

[pscustomobject]@{
    ok = $true
    chunks = $chunks.Count
    sourceFiles = @(Get-ChildItem -LiteralPath $generatedRoot -Recurse -File -Filter "*.md").Count
    sourceCharacters = ($chunks | ForEach-Object { $_.text.Length } | Measure-Object -Sum).Sum
    sandboxPaths = $sourcePaths.Count
    missingPaths = $missing.Count
    inventedPathSanitized = $unknownSanitized -notmatch 'SandboxVars\.NotInSource\.Enabled'
    excessiveInventedPathsRejected = $excessiveUnknownRejected
    credentialRejected = $secretRejected
    nestedResponsesParsed = $nestedText -match 'Parsed correctly'
    tokenLimitDiagnosed = $tokenLimitDiagnosed
    flashAutoEffort = $flashAutoEffort
    proAutoEffort = $proAutoEffort
    explicitHighEffort = $explicitHighEffort
    deepSeekHighRejected = $deepSeekHighRejected
    chatEffort = $chatEffort
} | ConvertTo-Json
