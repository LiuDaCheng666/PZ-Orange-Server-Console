$ErrorActionPreference = "Stop"
$sourcePath = Join-Path $PSScriptRoot "PZ-AIBridge.ps1"
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw "PZ-AIBridge.ps1 has parse errors." }

$functionAst = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq "ConvertFrom-AIStockNewsResponse"
}, $true))[0]
if (-not $functionAst) { throw "Stock event response parser was not found." }
Invoke-Expression $functionAst.Extent.Text

function Get-AIResponseTextRaw {
    param([string]$Json)
    return [string](($Json | ConvertFrom-Json).text)
}

$script:aiConfig = [pscustomobject]@{ stockNewsMaxCharacters = 240 }
$request = [pscustomobject]@{
    rows = @([pscustomobject]@{ id = "orange" })
    stockEventRequestId = "stock-event-trusted"
    updateHour = 30
}

function New-ProviderEnvelope {
    param($Event)
    return @{
        text = (@{
            title = "测试快讯"; body = "测试正文"; sentiment = "neutral"; event = $Event
        } | ConvertTo-Json -Compress -Depth 5)
    } | ConvertTo-Json -Compress -Depth 6
}

function Assert-Rejected {
    param($Event, [string]$Name)
    $thrown = $false
    try { [void](ConvertFrom-AIStockNewsResponse -Json (New-ProviderEnvelope $Event) -Request $request) }
    catch { $thrown = $true }
    if (-not $thrown) { throw "Unsafe stock event was accepted: $Name" }
}

$valid = ConvertFrom-AIStockNewsResponse -Json (New-ProviderEnvelope @{
    type = "profit"; stockId = "orange"; magnitudePercent = 4.5; durationHours = 6
    summary = "阶段性盈利"; requestId = "model-forged"; gameHour = 999
    price = 0; wallet = 999999
}) -Request $request
if (-not $valid.event -or $valid.event.type -cne "profit" -or $valid.event.stockId -cne "orange" -or
        $valid.event.magnitudePercent -ne 4.5 -or $valid.event.durationHours -ne 6 -or
        $valid.event.PSObject.Properties["requestId"] -or $valid.event.PSObject.Properties["gameHour"] -or
        $valid.event.PSObject.Properties["price"] -or $valid.event.PSObject.Properties["wallet"]) {
    throw "Valid event normalization retained untrusted command fields or lost safe fields."
}

$none = ConvertFrom-AIStockNewsResponse -Json (New-ProviderEnvelope $null) -Request $request
if ($null -ne $none.event) { throw "Null event must remain null." }

Assert-Rejected @{ type = "pump"; stockId = "orange"; magnitudePercent = 5; durationHours = 6; summary = "非法类型" } "unknown type"
Assert-Rejected @{ type = "profit"; stockId = "unknown"; magnitudePercent = 5; durationHours = 6; summary = "未知股票" } "unknown stock"
Assert-Rejected @{ type = "profit"; stockId = "orange"; magnitudePercent = 10.01; durationHours = 6; summary = "幅度越界" } "magnitude"
Assert-Rejected @{ type = "halt"; stockId = "orange"; magnitudePercent = 1; durationHours = 6; summary = "停牌不能改价" } "halt magnitude"
Assert-Rejected @{ type = "crisis"; stockId = "orange"; magnitudePercent = -10; durationHours = 5; summary = "持续时间越界" } "duration"
Assert-Rejected @{ type = "loss"; stockId = "orange"; magnitudePercent = -5; durationHours = 6; summary = ("x" * 81) } "summary length"

[pscustomobject]@{
    ok = $true
    allowedTypes = @("profit", "loss", "crisis", "halt", "delist_candidate")
    trustedFields = @("requestId", "gameHour")
    rejectedCases = 6
    directPriceOrWalletFields = $false
} | ConvertTo-Json -Depth 4
