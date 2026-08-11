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

foreach ($name in @('Get-PublicUser', 'Test-PlayerDataPermission', 'Assert-PlayerDataPermission', 'Assert-HostControlAdministrator')) {
    Import-PanelFunction -Name $name
}

function New-TestSession {
    param([string]$Username, [AllowNull()][Nullable[bool]]$CanManagePlayerData = $null)
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
    return [pscustomobject]@{ user = $user }
}

$admin = New-TestSession -Username 'admin'
$legacyUser = New-TestSession -Username 'legacy-user'
$grantedUser = New-TestSession -Username 'operator' -CanManagePlayerData $true
$deniedUser = New-TestSession -Username 'viewer' -CanManagePlayerData $false

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

$publicAdmin = Get-PublicUser $admin.user
$publicGranted = Get-PublicUser $grantedUser.user
$publicLegacy = Get-PublicUser $legacyUser.user
if (-not $publicAdmin.canManagePlayerData -or -not $publicGranted.canManagePlayerData -or $publicLegacy.canManagePlayerData) {
    throw 'Public user permission serialization is inconsistent.'
}

[pscustomobject]@{
    ok = $true
    adminAlwaysAllowed = $true
    legacyDefaultsDenied = $true
    grantedUserAllowed = $true
    deniedUserRejected = $true
    hostControlRemainsAdminOnly = $true
} | ConvertTo-Json
