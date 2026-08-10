param(
    [Parameter(Mandatory = $true)]
    [ValidateRange(1024, 65535)]
    [int]$Port,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"
$definitions = @(
    [pscustomobject]@{ Name = "PZ Server Control Panel LAN"; Profile = "Private"; RemoteAddress = "LocalSubnet" },
    [pscustomobject]@{ Name = "PZ Server Control Panel Public"; Profile = "Any"; RemoteAddress = "Any" }
)

function Test-FirewallRules {
    foreach ($definition in $definitions) {
        $rule = Get-NetFirewallRule -DisplayName $definition.Name -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $rule) { return $false }
        $portFilter = $rule | Get-NetFirewallPortFilter
        $addressFilter = $rule | Get-NetFirewallAddressFilter
        if ($rule.Enabled -ne "True" -or $rule.Direction -ne "Inbound" -or $rule.Action -ne "Allow" -or
            [string]$rule.Profile -ne $definition.Profile -or [string]$portFilter.Protocol -ne "TCP" -or
            [string]$portFilter.LocalPort -ne [string]$Port -or
            (@($addressFilter.RemoteAddress) -join ",") -ne $definition.RemoteAddress) {
            return $false
        }
    }
    return $true
}

$isAdministrator = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdministrator -and -not (Test-FirewallRules)) {
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Port $Port -Quiet"
    $elevated = Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    if ($elevated.ExitCode -ne 0) { throw "防火墙规则创建失败，管理员进程退出码 $($elevated.ExitCode)。" }
    if (-not (Test-FirewallRules)) { throw "管理员进程结束后，防火墙规则仍未生效。" }
}

$results = @()
if ($isAdministrator) {
    foreach ($definition in $definitions) {
        $rule = Get-NetFirewallRule -DisplayName $definition.Name -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $rule) {
            $rule = New-NetFirewallRule -DisplayName $definition.Name -Direction Inbound -Action Allow -Enabled True `
                -Protocol TCP -LocalPort $Port -Profile $definition.Profile -RemoteAddress $definition.RemoteAddress
        }
        else {
            $rule | Set-NetFirewallRule -Direction Inbound -Action Allow -Enabled True -Profile $definition.Profile | Out-Null
            $rule | Get-NetFirewallPortFilter | Set-NetFirewallPortFilter -Protocol TCP -LocalPort $Port | Out-Null
            $rule | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -RemoteAddress $definition.RemoteAddress | Out-Null
            $rule = Get-NetFirewallRule -DisplayName $definition.Name
        }
        $portFilter = $rule | Get-NetFirewallPortFilter
        $addressFilter = $rule | Get-NetFirewallAddressFilter
        if ($rule.Enabled -ne "True" -or $rule.Direction -ne "Inbound" -or $rule.Action -ne "Allow" -or
            [string]$portFilter.Protocol -ne "TCP" -or [string]$portFilter.LocalPort -ne [string]$Port) {
            throw "防火墙规则 $($definition.Name) 校验失败。"
        }
    }
}

foreach ($definition in $definitions) {
    $rule = Get-NetFirewallRule -DisplayName $definition.Name -ErrorAction Stop | Select-Object -First 1
    $portFilter = $rule | Get-NetFirewallPortFilter
    $addressFilter = $rule | Get-NetFirewallAddressFilter
    $results += [pscustomobject]@{
        Name = $definition.Name
        Port = [int]$portFilter.LocalPort
        Profile = [string]$rule.Profile
        RemoteAddress = @($addressFilter.RemoteAddress) -join ","
        Enabled = [bool]($rule.Enabled -eq "True")
    }
}

if ($Quiet) { return $results }
$results | Format-Table -AutoSize
