param()

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot

function Import-PanelFunction {
    param([string]$Name)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'PZ-ControlPanel.ps1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw 'Panel script does not parse.' }
    $functionAst = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name
    }, $true)
    if (-not $functionAst) { throw "Function not found: $Name" }
    Set-Item -LiteralPath "Function:\script:$Name" -Value $functionAst.Body.GetScriptBlock()
}

foreach ($name in @('Get-PublicUser', 'Test-PlayerDataPermission', 'Assert-PlayerDataPermission',
        'Test-EconomyViewPermission', 'Assert-EconomyViewPermission',
        'Test-EconomyManagePermission', 'Assert-EconomyManagePermission',
        'Assert-HostControlAdministrator')) {
    Import-PanelFunction -Name $name
}

function New-TestSession {
    param(
        [string]$Username,
        [AllowNull()][Nullable[bool]]$CanManagePlayerData = $null,
        [AllowNull()][Nullable[bool]]$CanViewEconomy = $null,
        [AllowNull()][Nullable[bool]]$CanManageEconomy = $null
    )
    $user = [pscustomobject]@{
        id = [guid]::NewGuid().ToString('N')
        username = $Username
        displayName = $Username
        enabled = $true
        createdAt = (Get-Date).ToString('o')
        updatedAt = (Get-Date).ToString('o')
    }
    if ($null -ne $CanManagePlayerData) {
        $user | Add-Member -NotePropertyName canManagePlayerData -NotePropertyValue ([bool]$CanManagePlayerData)
    }
    if ($null -ne $CanViewEconomy) {
        $user | Add-Member -NotePropertyName canViewEconomy -NotePropertyValue ([bool]$CanViewEconomy)
    }
    if ($null -ne $CanManageEconomy) {
        $user | Add-Member -NotePropertyName canManageEconomy -NotePropertyValue ([bool]$CanManageEconomy)
    }
    return [pscustomobject]@{ user = $user }
}

$admin = New-TestSession -Username 'admin'
$legacyUser = New-TestSession -Username 'legacy-user'
$grantedUser = New-TestSession -Username 'operator' -CanManagePlayerData $true
$deniedUser = New-TestSession -Username 'viewer' -CanManagePlayerData $false
$economyViewer = New-TestSession -Username 'economy-viewer' -CanViewEconomy $true -CanManageEconomy $false
$economyManager = New-TestSession -Username 'economy-manager' -CanViewEconomy $false -CanManageEconomy $true

if (-not (Test-PlayerDataPermission $admin)) { throw 'The reserved admin account lost player-data permission.' }
if (Test-PlayerDataPermission $legacyUser) { throw 'A legacy user without the permission field was granted access.' }
if (-not (Test-PlayerDataPermission $grantedUser)) { throw 'An explicitly granted user was denied access.' }
if (Test-PlayerDataPermission $deniedUser) { throw 'An explicitly denied user was granted access.' }

Assert-PlayerDataPermission $admin
Assert-PlayerDataPermission $grantedUser
$playerDataDenied = $false
try { Assert-PlayerDataPermission $deniedUser } catch { $playerDataDenied = $true }
if (-not $playerDataDenied) { throw 'Denied player-data access did not raise an error.' }

Assert-HostControlAdministrator $admin
$hostDenied = $false
try { Assert-HostControlAdministrator $grantedUser } catch { $hostDenied = $true }
if (-not $hostDenied) { throw 'Player-data permission incorrectly granted host-control administration.' }

if (-not (Test-EconomyViewPermission $admin) -or -not (Test-EconomyManagePermission $admin)) {
    throw 'The reserved admin account lost economy permissions.'
}
if ((Test-EconomyViewPermission $legacyUser) -or (Test-EconomyManagePermission $legacyUser)) {
    throw 'A legacy user without economy fields was granted access.'
}
if (-not (Test-EconomyViewPermission $economyViewer) -or (Test-EconomyManagePermission $economyViewer)) {
    throw 'Economy view-only permission is inconsistent.'
}
if (-not (Test-EconomyViewPermission $economyManager) -or -not (Test-EconomyManagePermission $economyManager)) {
    throw 'Economy management permission did not imply view permission.'
}
Assert-EconomyViewPermission $economyViewer
$economyManageDenied = $false
try { Assert-EconomyManagePermission $economyViewer } catch { $economyManageDenied = $true }
if (-not $economyManageDenied) { throw 'Economy view-only user was allowed to manage economy data.' }
Assert-EconomyViewPermission $economyManager
Assert-EconomyManagePermission $economyManager

$publicAdmin = Get-PublicUser $admin.user
$publicGranted = Get-PublicUser $grantedUser.user
$publicLegacy = Get-PublicUser $legacyUser.user
$publicEconomyViewer = Get-PublicUser $economyViewer.user
$publicEconomyManager = Get-PublicUser $economyManager.user
if (-not $publicAdmin.canManagePlayerData -or -not $publicGranted.canManagePlayerData -or $publicLegacy.canManagePlayerData) {
    throw 'Public user permission serialization is inconsistent.'
}
if (-not $publicAdmin.canViewEconomy -or -not $publicAdmin.canManageEconomy -or
        $publicLegacy.canViewEconomy -or $publicLegacy.canManageEconomy -or
        -not $publicEconomyViewer.canViewEconomy -or $publicEconomyViewer.canManageEconomy -or
        -not $publicEconomyManager.canViewEconomy -or -not $publicEconomyManager.canManageEconomy) {
    throw 'Public economy permission serialization is inconsistent.'
}

[pscustomobject]@{
    ok = $true
    adminAlwaysAllowed = $true
    legacyDefaultsDenied = $true
    grantedUserAllowed = $true
    deniedUserRejected = $true
    hostControlRemainsAdminOnly = $true
    economyAdminAlwaysAllowed = $true
    economyLegacyDefaultsDenied = $true
    economyViewAndManageSeparated = $true
    economyManageImpliesView = $true
} | ConvertTo-Json
