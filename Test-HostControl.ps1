param()

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot

function Assert-PowerShellSyntax {
    param([string]$Path)
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "$([IO.Path]::GetFileName($Path)) syntax failed: $($errors[0].Message)" }
}

$panelPath = Join-Path $root "PZ-ControlPanel.ps1"
$startupTaskPath = Join-Path $root "Set-PZPanelStartupTask.ps1"
$startupRunnerPath = Join-Path $root "Run-PZPanelAtStartup.ps1"
$autoLogonPath = Join-Path $root "Configure-PZPanelAutoLogon.ps1"
foreach ($path in @($panelPath, $startupTaskPath, $startupRunnerPath, $autoLogonPath)) { Assert-PowerShellSyntax -Path $path }

$panel = Get-Content -LiteralPath $panelPath -Raw -Encoding UTF8
$html = Get-Content -LiteralPath (Join-Path $root "web\index.html") -Raw -Encoding UTF8
$javascript = Get-Content -LiteralPath (Join-Path $root "web\app.js") -Raw -Encoding UTF8
$autoLogon = Get-Content -LiteralPath $autoLogonPath -Raw -Encoding UTF8

if ($panel -notmatch 'Assert-HostControlAdministrator' -or $panel -notmatch 'username\s+-ine\s+"admin"') {
    throw "Physical host control is not restricted to the reserved admin account."
}
if ($panel -notmatch 'RESTART_PHYSICAL_HOST' -or $panel -notmatch 'allServersStopped' -or
        $panel -notmatch 'Where-Object\s+\{\s*\[bool\]\$_\.alive\s*\}') {
    throw "Physical host restart safety checks are incomplete."
}
if ($panel -notmatch '/api/host/restart/cancel' -or $panel -notmatch 'shutdown\.exe' -or $panel -notmatch '/a') {
    throw "Host restart cancellation is missing."
}
if ($html -notmatch 'id="restartPhysicalHost"' -or $html -notmatch 'id="toggleHostStartup"' -or
        $html -notmatch 'id="openHostAutoLogon"') {
    throw "Host controls are missing from the system page."
}
if ($panel -notmatch '/api/host/autologon/launcher' -or $panel -match 'Start-Process.+hostAutoLogonScript') {
    throw "Autologon must use a local launcher download instead of cross-session UI launch."
}
if ($panel -notmatch '\[uint32\]::MaxValue' -or
        (Get-Content -LiteralPath $startupTaskPath -Raw -Encoding UTF8) -notmatch '\[uint32\]::MaxValue') {
    throw "Scheduled-task UInt32 placeholder results are not normalized safely."
}
if ($javascript -notmatch "typed!=='重启物理机'" -or $javascript -notmatch 'RESTART_PHYSICAL_HOST') {
    throw "The browser does not require typed physical-host confirmation."
}
if ($panel -notmatch 'Win32_PerfFormattedData_PerfOS_Processor' -or $panel -notmatch 'logicalProcessors = \$logicalProcessorLoads' -or
        $html -notmatch 'id="cpuCoreGrid"' -or $javascript -notmatch 'cpu-core-tile') {
    throw "Per-logical-processor monitoring is incomplete."
}
if ($autoLogon -notmatch 'https://live\.sysinternals\.com/Autologon64\.exe' -or
        $autoLogon -match 'DefaultPassword|password\s*=|ConvertFrom-SecureString') {
    throw "Autologon configuration must use the official local tool without Web password storage."
}

$taskStatus = & $startupTaskPath -Mode Status
if ($null -ne $taskStatus.lastTaskResult -and [int64]$taskStatus.lastTaskResult -gt [uint32]::MaxValue) {
    throw "Scheduled-task result exceeded the supported UInt32 range."
}
[pscustomobject]@{
    ok = $true
    syntax = $true
    adminOnly = $true
    csrfProtected = $true
    typedRestartConfirmation = $true
    runningServerGuard = $true
    restartCancellation = $true
    passwordNotHandledByPanel = $true
    startupTaskInstalled = [bool]$taskStatus.enabled
    startupTaskState = [string]$taskStatus.state
    startupTaskLastResult = $taskStatus.lastTaskResult
} | ConvertTo-Json
