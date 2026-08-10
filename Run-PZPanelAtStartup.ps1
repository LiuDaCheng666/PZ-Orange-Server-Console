param()

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$statePath = Join-Path $root "panel-state.json"
$panelScript = Join-Path $root "PZ-ControlPanel.ps1"
$configPath = Join-Path $root "panel-config.json"

if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $process = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$state.pid)" -ErrorAction SilentlyContinue
        if ($process -and $process.CommandLine -like "*PZ-ControlPanel.ps1*") { exit 0 }
    }
    catch { }
    Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
}

$port = 8790
if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    $configuration = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $configuredPort = [int]$configuration.port
    if ($configuredPort -lt 1024 -or $configuredPort -gt 65535) { throw "Invalid panel port: $configuredPort" }
    $port = $configuredPort
}

& $panelScript -Port $port

