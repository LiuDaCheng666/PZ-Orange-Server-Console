param()

$ErrorActionPreference = "Stop"
$projectRoot = $PSScriptRoot
$testRoot = Join-Path $env:TEMP ("PZMaintenanceRestart-" + [guid]::NewGuid().ToString("N"))
$operationPath = Join-Path $testRoot "lifecycle-operation.json"
$utf8 = [Text.UTF8Encoding]::new($false)

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

Import-PanelFunction -Name "Sync-AutomaticModRestartState"
Import-PanelFunction -Name "Complete-ScheduledModCheck"
function Get-ManagedProfilePaths { param([string]$Id) return @{ operationPath = $script:operationPath } }

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $profile = [pscustomobject]@{ id = "mock" }
    $schedule = [pscustomobject]@{
        lastAutoRestartOperationId = "0123456789abcdef0123456789abcdef"
        lastAutoRestartAt = (Get-Date).AddMinutes(-10).ToString("o")
        lastAutoRestartStatus = "queued"
        updateNotificationPending = $true
        lastStatus = "auto-restart-queued"
        lastResultCode = "mods-update-required"
        lastMessage = "queued"
        autoRestartOnUpdate = $true
        restartStabilizationSeconds = 60
    }
    $operation = [ordered]@{
        id = $schedule.lastAutoRestartOperationId
        status = "completed"
        message = "restart complete"
        error = ""
    }
    [IO.File]::WriteAllText($operationPath, ($operation | ConvertTo-Json), $utf8)
    if (-not (Sync-AutomaticModRestartState -Profile $profile -Schedule $schedule)) { throw "Completed operation did not update the schedule." }
    if ($schedule.updateNotificationPending -or $schedule.lastAutoRestartStatus -ne "completed" -or $schedule.lastStatus -ne "auto-restart-completed") {
        throw "Completed automatic restart did not release the update lock."
    }

    $schedule.updateNotificationPending = $true
    $schedule.lastAutoRestartStatus = "running"
    $schedule.lastStatus = "checking"
    $operation.status = "running"
    [IO.File]::WriteAllText($operationPath, ($operation | ConvertTo-Json), $utf8)
    [void](Sync-AutomaticModRestartState -Profile $profile -Schedule $schedule)
    if (-not $schedule.updateNotificationPending) { throw "Running operation released the update lock too early." }

    $operation.status = "completed"
    [IO.File]::WriteAllText($operationPath, ($operation | ConvertTo-Json), $utf8)
    $schedule.updateNotificationPending = $true
    $schedule.lastAutoRestartStatus = "running"
    $schedule.lastStatus = "checking"
    $script:maintenanceChecks = @{ request1 = [pscustomobject]@{ serverId = "mock" } }
    $script:autoRestartCalls = 0
    function Get-ServerProfile { param([string]$Id) return $profile }
    function Get-MaintenanceSchedule { param([string]$ServerId) return $schedule }
    function Get-CommandResultPayload { return [pscustomobject]@{ done = $true; resultCode = "mods-update-required"; status = "response" } }
    function Start-AutomaticModRestart {
        param($Profile, $Schedule)
        $script:autoRestartCalls += 1
        $Schedule.updateNotificationPending = $true
        $Schedule.lastAutoRestartStatus = "queued"
        return "fedcba9876543210fedcba9876543210"
    }
    function Save-MaintenanceSchedules { }
    function Add-Audit { param($Remote, $Action, $Detail, $Result) }
    function Add-ExecutionHistoryRecord { return $null }
    Complete-ScheduledModCheck -RequestId "request1"
    if ($autoRestartCalls -ne 1 -or $schedule.lastStatus -ne "auto-restart-queued") {
        throw "A new update after a completed automatic restart did not queue another restart."
    }

    $schedule.lastAutoRestartOperationId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    $schedule.lastAutoRestartAt = (Get-Date).AddMinutes(-5).ToString("o")
    $schedule.lastAutoRestartStatus = "queued"
    $schedule.updateNotificationPending = $true
    $schedule.lastStatus = "update-required"
    $operation.id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    $operation.action = "restart"
    $operation.status = "completed"
    $operation.startedAt = (Get-Date).AddMinutes(-2).ToString("o")
    [IO.File]::WriteAllText($operationPath, ($operation | ConvertTo-Json), $utf8)
    if (-not (Sync-AutomaticModRestartState -Profile $profile -Schedule $schedule) -or $schedule.updateNotificationPending) {
        throw "A newer completed manual restart did not release the stale automatic update lock."
    }

    [pscustomobject]@{
        ok = $true
        completedReleasesLock = $true
        runningKeepsLock = $true
        newUpdateQueuesRestart = $true
        manualRestartReleasesStaleLock = $true
    } | ConvertTo-Json
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
