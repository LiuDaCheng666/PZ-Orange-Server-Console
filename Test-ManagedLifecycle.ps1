param(
    [switch]$ShowConsole
)

$ErrorActionPreference = "Stop"
$projectRoot = $PSScriptRoot
$testRoot = Join-Path $env:TEMP ("PZManagedLifecycle-" + [guid]::NewGuid().ToString("N"))
$managedRoot = Join-Path $testRoot "managed"
$profileRoot = Join-Path $managedRoot "mock"
$utf8 = [Text.UTF8Encoding]::new($false)
$restartProcess = $null
$decoyProcess = $null
$consoleWindowHandle = 0

function Wait-ForCondition {
    param([scriptblock]$Condition, [int]$TimeoutSeconds, [string]$Failure)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw $Failure
}

try {
    New-Item -ItemType Directory -Path $managedRoot, $profileRoot -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $projectRoot "managed\Run-ManagedPZHost.ps1") -Destination $managedRoot
    Copy-Item -LiteralPath (Join-Path $projectRoot "managed\Invoke-ManagedPZLifecycle.ps1") -Destination $managedRoot
    $startSource = @'
param([string]$AdminPasswordSecretPath)
$ErrorActionPreference = "Stop"
$hostScript = Join-Path (Split-Path -Parent $PSScriptRoot) "Run-ManagedPZHost.ps1"
$profilePath = Join-Path $PSScriptRoot "profile.json"
& $hostScript -ProfilePath $profilePath -AdminPasswordSecretPath $AdminPasswordSecretPath
'@
    [IO.File]::WriteAllText((Join-Path $profileRoot "Start-ManagedPZ.ps1"), $startSource, $utf8)

    $mockPath = Join-Path $profileRoot "Mock-ManagedServer.ps1"
    $runMarker = Join-Path $profileRoot "runs.log"
    $mockSource = @'
param(
    [string]$RunMarker,
    [string]$ConsoleLog,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$IgnoredArguments
)
$utf8 = [Text.UTF8Encoding]::new($false)
[IO.File]::AppendAllText($RunMarker, "started $PID " + (Get-Date).ToString("o") + "`r`n", $utf8)
Start-Sleep -Milliseconds 500
[IO.File]::AppendAllText($ConsoleLog, "*** SERVER STARTED ****`r`n", $utf8)
while ($true) {
    $command = [Console]::In.ReadLine()
    if ($null -eq $command) { Start-Sleep -Milliseconds 100; continue }
    [IO.File]::AppendAllText($RunMarker, "command $command`r`n", $utf8)
    if ($command -eq "quit") { exit 0 }
}
'@
    [IO.File]::WriteAllText($mockPath, $mockSource, $utf8)

    $powershellPath = (Get-Command powershell.exe).Source
    $mockJavaPath = Join-Path $profileRoot "java.exe"
    Copy-Item -LiteralPath $powershellPath -Destination $mockJavaPath
    $decoyMarker = Join-Path $profileRoot "decoy-runs.log"
    $decoyArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$mockPath`" -RunMarker `"$decoyMarker`" zombie.network.GameServer -cachedir=`"$profileRoot\other-data`" -servername=other"
    $decoyProcess = Start-Process -FilePath $mockJavaPath -ArgumentList $decoyArguments -WindowStyle Hidden -PassThru
    Wait-ForCondition -TimeoutSeconds 10 -Failure "Decoy Java process did not start." -Condition {
        return -not $decoyProcess.HasExited -and (Test-Path -LiteralPath $decoyMarker)
    }

    $profile = [ordered]@{
        id = "mock"
        serverName = "mock"
        dataRoot = Join-Path $profileRoot "data"
        javaPath = $mockJavaPath
        workingDirectory = $profileRoot
        arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$mockPath`" -RunMarker `"$runMarker`" -ConsoleLog `"$(Join-Path $profileRoot 'mock-console.txt')`" zombie.network.GameServer -cachedir=`"$(Join-Path $profileRoot 'data')`" -servername=mock"
        queueDir = Join-Path $profileRoot "commands"
        receiptDir = Join-Path $profileRoot "receipts"
        statePath = Join-Path $profileRoot "state.json"
        consoleLog = Join-Path $profileRoot "mock-console.txt"
        showConsole = [bool]$ShowConsole
    }
    [IO.File]::WriteAllText((Join-Path $profileRoot "profile.json"), ($profile | ConvertTo-Json -Depth 4), $utf8)
    $databaseRoot = Join-Path $profile.dataRoot "db"
    New-Item -ItemType Directory -Path $databaseRoot -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $databaseRoot "mock.db"), [byte[]](1))
    $luaRoot = Join-Path $profile.dataRoot "Lua"
    New-Item -ItemType Directory -Path $luaRoot -Force | Out-Null
    $heartbeat = "version=0.2.3`nupdatedMs=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())`nonline=2`n"
    [IO.File]::WriteAllText((Join-Path $luaRoot "PZWebNotices-heartbeat.ini"), $heartbeat, $utf8)

    $startScript = Join-Path $profileRoot "Start-ManagedPZ.ps1"
    $windowStyle = if ($ShowConsole) { "Normal" } else { "Hidden" }
    Start-Process -FilePath powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$startScript`"" -WindowStyle $windowStyle
    Wait-ForCondition -TimeoutSeconds 15 -Failure "Mock managed server did not start." -Condition {
        if (-not (Test-Path -LiteralPath $profile.statePath)) { return $false }
        $state = Get-Content -LiteralPath $profile.statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        return [string]$state.status -eq "running" -and [int]$state.protocolVersion -eq 2
    }
    $firstState = Get-Content -LiteralPath $profile.statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$firstState.priorityClass -cne "AboveNormal") {
        throw "Managed startup did not record the AboveNormal Java priority."
    }
    $firstJavaProcess = Get-Process -Id ([int]$firstState.javaPid) -ErrorAction Stop
    if ($firstJavaProcess.PriorityClass -ne [Diagnostics.ProcessPriorityClass]::AboveNormal) {
        throw "Managed startup did not apply the AboveNormal Java priority."
    }
    $sensitiveRequestId = [guid]::NewGuid().ToString("N")
    $sensitiveRequest = [ordered]@{
        id = $sensitiveRequestId
        createdAt = (Get-Date).ToString("o")
        command = 'setpassword "Alice" "test-secret"'
        requireReceipt = $true
        redactReceipt = $true
    }
    [IO.File]::WriteAllText((Join-Path $profile.queueDir "$sensitiveRequestId.json"), ($sensitiveRequest | ConvertTo-Json -Compress), $utf8)
    $sensitiveReceiptPath = Join-Path $profile.receiptDir "$sensitiveRequestId.json"
    Wait-ForCondition -TimeoutSeconds 10 -Failure "Sensitive command receipt was not completed." -Condition {
        if (-not (Test-Path -LiteralPath $sensitiveReceiptPath)) { return $false }
        $receipt = Get-Content -LiteralPath $sensitiveReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return [string]$receipt.status -eq "completed"
    }
    $sensitiveReceipt = Get-Content -LiteralPath $sensitiveReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$sensitiveReceipt.command -cne "[redacted]") { throw "Sensitive command was persisted in a managed receipt." }
    if (-not (Get-Content -LiteralPath $runMarker -Raw -Encoding UTF8).Contains('command setpassword "Alice" "test-secret"')) {
        throw "Sensitive command was not delivered to the managed server."
    }
    if ($ShowConsole) {
        Wait-ForCondition -TimeoutSeconds 10 -Failure "Managed host did not expose a visible console window." -Condition {
            $hostProcess = Get-Process -Id ([int]$firstState.hostPid) -ErrorAction SilentlyContinue
            if (-not $hostProcess) { return $false }
            $script:consoleWindowHandle = [int64]$hostProcess.MainWindowHandle
            return $script:consoleWindowHandle -ne 0
        }
    }

    $operationId = [guid]::NewGuid().ToString("N")
    $lifecycleScript = Join-Path $managedRoot "Invoke-ManagedPZLifecycle.ps1"
    $restartProcess = Start-Process -FilePath powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$lifecycleScript`" -Action restart -OperationId $operationId -ProfilePath `"$(Join-Path $profileRoot 'profile.json')`" -WarningSeconds 1 -RestartStabilizationSeconds 10" -WindowStyle Hidden -PassThru
    Wait-ForCondition -TimeoutSeconds 45 -Failure "Managed restart did not complete." -Condition {
        if (-not $restartProcess.HasExited -or -not (Test-Path -LiteralPath $profile.statePath)) { return $false }
        $state = Get-Content -LiteralPath $profile.statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $starts = @((Get-Content -LiteralPath $runMarker -ErrorAction SilentlyContinue) | Where-Object { $_ -like "started *" })
        return [string]$state.status -eq "running" -and [int]$state.javaPid -ne [int]$firstState.javaPid -and $starts.Count -ge 2
    }
    $finalState = Get-Content -LiteralPath $profile.statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$finalState.priorityClass -cne "AboveNormal") {
        throw "Managed restart did not preserve the AboveNormal Java priority."
    }
    $restartedJavaProcess = Get-Process -Id ([int]$finalState.javaPid) -ErrorAction Stop
    if ($restartedJavaProcess.PriorityClass -ne [Diagnostics.ProcessPriorityClass]::AboveNormal) {
        throw "Managed restart did not apply the AboveNormal Java priority."
    }
    $operation = Get-Content -LiteralPath (Join-Path $profileRoot "lifecycle-operation.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$operation.id -cne $operationId -or [string]$operation.status -ne "completed" -or
        [int]$operation.oldJavaPid -ne [int]$firstState.javaPid -or [int]$operation.newJavaPid -ne [int]$finalState.javaPid -or
        [int]$operation.restartStabilizationSeconds -ne 10) {
        throw "Managed restart operation status did not record the completed PID transition."
    }
    $events = @(Get-Content -LiteralPath $runMarker -Encoding UTF8 | ForEach-Object { [string]$_ })
    if (@($events | Where-Object { $_ -eq "command save" }).Count -ne 1 -or
        @($events | Where-Object { $_ -eq "command quit" }).Count -ne 1) {
        throw "Mock server did not receive exactly one save and one quit command."
    }
    $broadcastIndex = [array]::FindIndex([string[]]$events, [Predicate[string]]{ param($line) $line -like 'command servermsg *' })
    $saveIndex = [array]::IndexOf([string[]]$events, "command save")
    $quitIndex = [array]::IndexOf([string[]]$events, "command quit")
    if ($broadcastIndex -lt 0 -or $broadcastIndex -ge $saveIndex -or $saveIndex -ge $quitIndex) {
        throw "Maintenance notification was not delivered before save and quit."
    }
    $noticeQueuePath = Join-Path $luaRoot "PZWebNotices-queue.txt"
    if (-not (Test-Path -LiteralPath $noticeQueuePath) -or (Get-Item -LiteralPath $noticeQueuePath).Length -eq 0) {
        throw "The popup maintenance notification queue was not written."
    }
    [pscustomobject]@{
        ok = $true
        firstJavaPid = [int]$firstState.javaPid
        restartedJavaPid = [int]$finalState.javaPid
        operationId = [string]$operation.id
        operationStatus = [string]$operation.status
        priorityClass = [string]$finalState.priorityClass
        ignoredDecoyPid = [int]$decoyProcess.Id
        showConsole = [bool]$ShowConsole
        consoleWindowHandle = $consoleWindowHandle
        events = $events
    } | ConvertTo-Json -Depth 4
}
finally {
    if (Test-Path -LiteralPath (Join-Path $profileRoot "state.json")) {
        try {
            $state = Get-Content -LiteralPath (Join-Path $profileRoot "state.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($processId in @($state.javaPid, $state.hostPid)) {
                if ($processId) { Stop-Process -Id ([int]$processId) -Force -ErrorAction SilentlyContinue }
            }
        } catch { }
    }
    if ($restartProcess -and -not $restartProcess.HasExited) { Stop-Process -Id $restartProcess.Id -Force -ErrorAction SilentlyContinue }
    if ($decoyProcess -and -not $decoyProcess.HasExited) { Stop-Process -Id $decoyProcess.Id -Force -ErrorAction SilentlyContinue }
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $resolvedTempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if ($resolvedTestRoot.StartsWith($resolvedTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
