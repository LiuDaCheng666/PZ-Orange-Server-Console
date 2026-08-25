param()

$ErrorActionPreference = "Stop"
$projectRoot = $PSScriptRoot
$testRoot = Join-Path $env:TEMP ("PZManagedLifecycleSerialization-" + [guid]::NewGuid().ToString("N"))
$managedRoot = Join-Path $testRoot "managed"
$utf8 = [Text.UTF8Encoding]::new($false)
$hostProcesses = @()
$lifecycleProcesses = @()

function Wait-ForCondition {
    param([scriptblock]$Condition, [int]$TimeoutSeconds, [string]$Failure)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
    throw $Failure
}

try {
    New-Item -ItemType Directory -Path $managedRoot -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $projectRoot "managed\Run-ManagedPZHost.ps1") -Destination $managedRoot
    Copy-Item -LiteralPath (Join-Path $projectRoot "managed\Invoke-ManagedPZLifecycle.ps1") -Destination $managedRoot

    $mockPath = Join-Path $testRoot "Mock-LifecycleServer.ps1"
    $eventsPath = Join-Path $testRoot "events.log"
    $mockSource = @'
param(
    [string]$ServerId,
    [string]$EventsPath,
    [string]$ConsoleLog,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$IgnoredArguments
)
$utf8 = [Text.UTF8Encoding]::new($false)
[IO.File]::AppendAllText($EventsPath, "started $ServerId " + (Get-Date).ToString("o") + "`r`n", $utf8)
[IO.File]::AppendAllText($ConsoleLog, "*** SERVER STARTED ****`r`n", $utf8)
while ($true) {
    $command = [Console]::In.ReadLine()
    if ($null -eq $command) { Start-Sleep -Milliseconds 100; continue }
    [IO.File]::AppendAllText($EventsPath, "command $ServerId $command " + (Get-Date).ToString("o") + "`r`n", $utf8)
    if ($command -eq "quit") {
        Start-Sleep -Seconds 4
        [IO.File]::AppendAllText($EventsPath, "quit-finished $ServerId " + (Get-Date).ToString("o") + "`r`n", $utf8)
        exit 0
    }
}
'@
    [IO.File]::WriteAllText($mockPath, $mockSource, $utf8)
    $mockJavaPath = Join-Path $testRoot "java.exe"
    Copy-Item -LiteralPath (Get-Command powershell.exe).Source -Destination $mockJavaPath

    foreach ($serverId in @("one", "two")) {
        $profileRoot = Join-Path $managedRoot $serverId
        $dataRoot = Join-Path $testRoot "data-$serverId"
        New-Item -ItemType Directory -Path $profileRoot, $dataRoot -Force | Out-Null
        $profile = [ordered]@{
            id = $serverId
            serverName = $serverId
            dataRoot = $dataRoot
            javaPath = $mockJavaPath
            workingDirectory = $testRoot
            arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$mockPath`" -ServerId $serverId -EventsPath `"$eventsPath`" -ConsoleLog `"$(Join-Path $dataRoot 'server-console.txt')`" zombie.network.GameServer -cachedir=`"$dataRoot`" -servername=$serverId"
            queueDir = Join-Path $profileRoot "commands"
            receiptDir = Join-Path $profileRoot "receipts"
            statePath = Join-Path $profileRoot "state.json"
            consoleLog = Join-Path $dataRoot "server-console.txt"
            showConsole = $false
        }
        $profilePath = Join-Path $profileRoot "profile.json"
        [IO.File]::WriteAllText($profilePath, ($profile | ConvertTo-Json -Depth 4), $utf8)
        $hostScript = Join-Path $managedRoot "Run-ManagedPZHost.ps1"
        $hostProcesses += Start-Process -FilePath powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$hostScript`" -ProfilePath `"$profilePath`"" -WindowStyle Hidden -PassThru
    }

    Wait-ForCondition -TimeoutSeconds 20 -Failure "Mock managed servers did not both reach running state." -Condition {
        foreach ($serverId in @("one", "two")) {
            $statePath = Join-Path $managedRoot "$serverId\state.json"
            if (-not (Test-Path -LiteralPath $statePath)) { return $false }
            $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$state.status -ne "running") { return $false }
        }
        return $true
    }

    $lifecycleScript = Join-Path $managedRoot "Invoke-ManagedPZLifecycle.ps1"
    $firstOperationId = [guid]::NewGuid().ToString("N")
    $firstProfilePath = Join-Path $managedRoot "one\profile.json"
    $lifecycleProcesses += Start-Process -FilePath powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$lifecycleScript`" -Action stop -OperationId $firstOperationId -ProfilePath `"$firstProfilePath`"" -WindowStyle Hidden -PassThru

    Wait-ForCondition -TimeoutSeconds 15 -Failure "First lifecycle operation did not reach shutdown wait." -Condition {
        $operationPath = Join-Path $managedRoot "one\lifecycle-operation.json"
        if (-not (Test-Path -LiteralPath $operationPath)) { return $false }
        $operation = Get-Content -LiteralPath $operationPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return [string]$operation.stage -eq "waiting-stop"
    }

    $secondOperationId = [guid]::NewGuid().ToString("N")
    $secondProfilePath = Join-Path $managedRoot "two\profile.json"
    $lifecycleProcesses += Start-Process -FilePath powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$lifecycleScript`" -Action stop -OperationId $secondOperationId -ProfilePath `"$secondProfilePath`"" -WindowStyle Hidden -PassThru

    Wait-ForCondition -TimeoutSeconds 10 -Failure "Second lifecycle operation did not report global lifecycle queueing." -Condition {
        $operationPath = Join-Path $managedRoot "two\lifecycle-operation.json"
        if (-not (Test-Path -LiteralPath $operationPath)) { return $false }
        $operation = Get-Content -LiteralPath $operationPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return [string]$operation.stage -eq "waiting-lifecycle-lock"
    }

    Wait-ForCondition -TimeoutSeconds 30 -Failure "Serialized lifecycle operations did not both complete." -Condition {
        return @($lifecycleProcesses | Where-Object { -not $_.HasExited }).Count -eq 0
    }

    foreach ($serverId in @("one", "two")) {
        $operation = Get-Content -LiteralPath (Join-Path $managedRoot "$serverId\lifecycle-operation.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$operation.status -ne "completed" -or [int]$operation.shutdownTimeoutSeconds -ne 900) {
            throw "Lifecycle operation $serverId did not complete with the 900-second shutdown timeout."
        }
    }

    $events = @(Get-Content -LiteralPath $eventsPath -Encoding UTF8 | ForEach-Object { [string]$_ })
    $firstFinishedIndex = [array]::FindIndex([string[]]$events, [Predicate[string]]{ param($line) $line -like "quit-finished one *" })
    $secondSaveIndex = [array]::FindIndex([string[]]$events, [Predicate[string]]{ param($line) $line -like "command two save *" })
    if ($firstFinishedIndex -lt 0 -or $secondSaveIndex -le $firstFinishedIndex) {
        throw "Global lifecycle lock allowed overlapping save/quit work."
    }

    $lockProbe = [IO.File]::Open((Join-Path $managedRoot "lifecycle-global.lock"), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $lockProbe.Dispose()

    $failedProfileRoot = Join-Path $managedRoot "failure"
    $failedDataRoot = Join-Path $testRoot "data-failure"
    New-Item -ItemType Directory -Path $failedProfileRoot, $failedDataRoot -Force | Out-Null
    $failedProfile = [ordered]@{
        id = "failure"
        serverName = "failure"
        dataRoot = $failedDataRoot
        javaPath = $mockJavaPath
        workingDirectory = $testRoot
        arguments = "zombie.network.GameServer -cachedir=`"$failedDataRoot`" -servername=failure"
        queueDir = Join-Path $failedProfileRoot "commands"
        receiptDir = Join-Path $failedProfileRoot "receipts"
        statePath = Join-Path $failedProfileRoot "state.json"
        consoleLog = Join-Path $failedDataRoot "server-console.txt"
        showConsole = $false
    }
    $failedProfilePath = Join-Path $failedProfileRoot "profile.json"
    [IO.File]::WriteAllText($failedProfilePath, ($failedProfile | ConvertTo-Json -Depth 4), $utf8)
    $failedOperationId = [guid]::NewGuid().ToString("N")
    $failedProcess = Start-Process -FilePath powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$lifecycleScript`" -Action restart -OperationId $failedOperationId -ProfilePath `"$failedProfilePath`" -WarningSeconds 0 -RestartStabilizationSeconds 10" -WindowStyle Hidden -PassThru
    $lifecycleProcesses += $failedProcess
    Wait-ForCondition -TimeoutSeconds 10 -Failure "Expected lifecycle failure did not exit." -Condition { return $failedProcess.HasExited }
    $failedOperation = Get-Content -LiteralPath (Join-Path $failedProfileRoot "lifecycle-operation.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$failedOperation.status -ne "failed" -or [string]$failedOperation.error -notlike "*账号数据库已缺失*") {
        throw "Failure-path lifecycle operation did not report the expected database guard."
    }
    $failureLockProbe = [IO.File]::Open((Join-Path $managedRoot "lifecycle-global.lock"), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $failureLockProbe.Dispose()

    [pscustomobject]@{
        ok = $true
        serialized = $true
        queuedStageObserved = $true
        failureReleasedLock = $true
        shutdownTimeoutSeconds = 900
        events = $events
    } | ConvertTo-Json -Depth 4
}
finally {
    foreach ($serverId in @("one", "two")) {
        $statePath = Join-Path $managedRoot "$serverId\state.json"
        if (-not (Test-Path -LiteralPath $statePath)) { continue }
        try {
            $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($processId in @($state.javaPid, $state.hostPid)) {
                if ($processId) { Stop-Process -Id ([int]$processId) -Force -ErrorAction SilentlyContinue }
            }
        }
        catch { }
    }
    foreach ($process in @($lifecycleProcesses) + @($hostProcesses)) {
        if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    }
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $resolvedTempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if ($resolvedTestRoot.StartsWith($resolvedTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
