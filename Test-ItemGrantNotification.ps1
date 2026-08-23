param()

$ErrorActionPreference = "Stop"
$projectRoot = $PSScriptRoot
$utf8 = [Text.UTF8Encoding]::new($false)
$commandRequests = @{}
$queuedCommands = @()
$noticeEntries = @()
$heartbeatMode = "ready"

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

foreach ($name in @("Assert-NoticeUtf8Text", "Invoke-ItemGrantNotification")) {
    Import-PanelFunction -Name $name
}

function Get-BroadcastCommands {
    param([string]$Message)
    return @("servermsg `"$Message`"")
}

function Queue-Command {
    param($Profile, [string]$Command, [bool]$RequireReceipt)
    $script:queuedCommands += $Command
    return [pscustomobject]@{ id = [guid]::NewGuid().ToString("N"); createdAt = (Get-Date).ToString("o") }
}

function Get-ServerState {
    param($Profile)
    return [pscustomobject]@{ alive = $true; onlineKnown = $true; onlineCount = 2 }
}

function Get-NoticeHeartbeat {
    param($Profile)
    if ($script:heartbeatMode -eq "ready") {
        return [pscustomobject]@{ installed = $true; usable = $true; v3Compatible = $true }
    }
    return [pscustomobject]@{ installed = $true; usable = $false; v3Compatible = $true }
}

function Add-NoticeQueueEntry {
    param(
        $Profile, [string]$Id, [string]$TargetType, [string]$TargetUsername,
        [string]$Style, [int]$Duration, [string]$TitleSize, [string]$BodySize,
        [string]$AccentColor, [string]$TextColor, [string]$Title, [string]$Message,
        [int]$ExpectedClients
    )
    $script:noticeEntries += [pscustomobject]@{
        id = $Id; targetType = $TargetType; targetUsername = $TargetUsername; style = $Style; duration = $Duration
        title = $Title; message = $Message; expectedClients = $ExpectedClients
    }
}

$profile = [pscustomobject]@{ id = "mock"; name = "Mock" }
$body = [pscustomobject]@{
    notificationChannel = "both"
    notificationMessage = "Items delivered."
    notificationDuration = 25
    item = "Base.Axe"
    count = 2
}

$both = Invoke-ItemGrantNotification -Profile $profile -Body $body -TargetCount 2 -LogCursor 0 -Targets @('Alice', 'Bob')
if ($both.requestIds.Count -ne 1 -or $both.channels.Count -ne 2 -or [string]::IsNullOrWhiteSpace([string]$both.noticeId)) {
    throw "Both-channel notification was not queued correctly."
}
if ($noticeEntries.Count -ne 2 -or $noticeEntries[0].duration -ne 25 -or $noticeEntries[0].expectedClients -ne 1 `
        -or $noticeEntries[0].targetType -cne 'player' -or $noticeEntries[0].targetUsername -cne 'Alice' `
        -or $both.noticeIds.Count -ne 2 -or $both.expectedClients -ne 2) {
    throw "Popup notification fields were not preserved."
}
if ($commandRequests.Count -ne 1 -or $queuedCommands.Count -ne 1) {
    throw "Native broadcast tracking was not created."
}

$script:heartbeatMode = "unavailable"
$popupBody = [pscustomobject]@{
    notificationChannel = "popup"
    notificationMessage = "Items delivered."
    notificationDuration = 10
    item = "Base.Axe"
    count = 1
}
$popup = Invoke-ItemGrantNotification -Profile $profile -Body $popupBody -TargetCount 1 -LogCursor 0 -Targets @('Alice')
if ($popup.noticeId -or $popup.warnings.Count -ne 1 -or $popup.warnings[0] -notmatch "PZWebNotices") {
    throw "Unavailable popup channel did not degrade to a warning."
}

$noneBody = [pscustomobject]@{ notificationChannel = "none"; item = "Base.Axe"; count = 1 }
$none = Invoke-ItemGrantNotification -Profile $profile -Body $noneBody -TargetCount 1 -LogCursor 0
if ($none.requestIds.Count -ne 0 -or $none.noticeId -or $none.warnings.Count -ne 0) {
    throw "Disabled notification unexpectedly queued work."
}

[pscustomobject]@{
    ok = $true
    bothChannels = @($both.channels)
    broadcastRequests = $both.requestIds.Count
    popupQueued = -not [string]::IsNullOrWhiteSpace([string]$both.noticeId)
    popupDuration = $noticeEntries[0].duration
    unavailablePopupWarning = [string]$popup.warnings[0]
    disabledChannelQueuedNothing = $true
} | ConvertTo-Json -Depth 4
