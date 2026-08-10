$ErrorActionPreference = "Stop"
$statePath = Join-Path $PSScriptRoot "panel-state.json"
$stopRequestPath = Join-Path $PSScriptRoot "panel-stop.request"
$startupTaskName = "PZ Orange Server Console - Startup"
$startupTask = Get-ScheduledTask -TaskName $startupTaskName -ErrorAction SilentlyContinue
$startupTaskWasEnabled = [bool]($startupTask -and $startupTask.Settings.Enabled)

if ($startupTaskWasEnabled -and [string]$startupTask.State -eq "Running") {
    Disable-ScheduledTask -TaskName $startupTaskName | Out-Null
}

$state = $null
try {
    if (Test-Path -LiteralPath $statePath) {
        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    $process = if ($state -and $state.pid) {
        Get-CimInstance Win32_Process -Filter "ProcessId=$($state.pid)" -ErrorAction SilentlyContinue
    }
    else { $null }
    $taskRunning = [bool]($startupTask -and [string](Get-ScheduledTask -TaskName $startupTaskName).State -eq "Running")
    if ($process -or $taskRunning) {
        [IO.File]::WriteAllText($stopRequestPath, (Get-Date).ToString("o"), [Text.UTF8Encoding]::new($false))
    }
    if ($process) {
        $deadline = (Get-Date).AddSeconds(10)
        do {
            Start-Sleep -Milliseconds 200
            $process = Get-Process -Id ([int]$state.pid) -ErrorAction SilentlyContinue
        } while ($process -and (Get-Date) -lt $deadline)
        if ($process) {
            Write-Warning "面板未在 10 秒内正常退出，将强制结束进程。"
            Stop-Process -Id ([int]$state.pid) -Force
        }
    }
    if ($startupTask -and [string](Get-ScheduledTask -TaskName $startupTaskName).State -eq "Running") {
        Stop-ScheduledTask -TaskName $startupTaskName
        $deadline = (Get-Date).AddSeconds(5)
        do {
            Start-Sleep -Milliseconds 200
            $taskState = [string](Get-ScheduledTask -TaskName $startupTaskName).State
        } while ($taskState -eq "Running" -and (Get-Date) -lt $deadline)
    }
}
finally {
    if ($startupTaskWasEnabled) { Enable-ScheduledTask -TaskName $startupTaskName | Out-Null }
}

Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $stopRequestPath -Force -ErrorAction SilentlyContinue
if ($state -or $startupTask) { Write-Host "控制台已停止；游戏服务器未停止。" }
else { Write-Host "控制台未运行。" }
