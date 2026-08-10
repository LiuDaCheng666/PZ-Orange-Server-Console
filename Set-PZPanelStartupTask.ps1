param(
    [ValidateSet("Status", "Enable", "Disable")]
    [string]$Mode = "Status"
)

$ErrorActionPreference = "Stop"
$taskName = "PZ Orange Server Console - Startup"
$runnerPath = Join-Path $PSScriptRoot "Run-PZPanelAtStartup.ps1"

function Get-TaskPayload {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    $info = if ($task) { Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue } else { $null }
    return [pscustomobject][ordered]@{
        taskName = $taskName
        enabled = [bool]($task -and $task.Settings.Enabled)
        state = if ($task) { [string]$task.State } else { "NotInstalled" }
        userId = if ($task) { [string]$task.Principal.UserId } else { $null }
        logonType = if ($task) { [string]$task.Principal.LogonType } else { $null }
        lastRunTime = if ($info -and $info.LastRunTime.Year -gt 2000) { $info.LastRunTime.ToString("o") } else { $null }
        lastTaskResult = if ($info) { [int]$info.LastTaskResult } else { $null }
        nextRunTime = if ($info -and $info.NextRunTime.Year -gt 2000) { $info.NextRunTime.ToString("o") } else { $null }
    }
}

if ($Mode -eq "Enable") {
    if (-not (Test-Path -LiteralPath $runnerPath -PathType Leaf)) { throw "Startup runner is missing: $runnerPath" }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$runnerPath`""
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arguments -WorkingDirectory $PSScriptRoot
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = "PT30S"
    $principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType S4U -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Days 3650)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
        -Description "Starts the PZ Orange Server Console before interactive desktop logon." -Force | Out-Null
}
elseif ($Mode -eq "Disable") {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
}

Get-TaskPayload

