param()

$ErrorActionPreference = "Stop"
$projectRoot = $PSScriptRoot
$testRoot = Join-Path $env:TEMP ("PZManagedStartupSerialization-" + [guid]::NewGuid().ToString("N"))
$managedRoot = Join-Path $testRoot "managed"
$utf8 = [Text.UTF8Encoding]::new($false)
$hostProcesses = @()

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
    $mockPath = Join-Path $testRoot "Mock-StartupServer.ps1"
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
[IO.File]::AppendAllText($EventsPath, "java-start $ServerId " + (Get-Date).ToString("o") + "`r`n", $utf8)
Start-Sleep -Milliseconds 1500
[IO.File]::AppendAllText($ConsoleLog, "*** SERVER STARTED ****`r`n", $utf8)
[IO.File]::AppendAllText($EventsPath, "ready $ServerId " + (Get-Date).ToString("o") + "`r`n", $utf8)
while ($true) {
    $command = [Console]::In.ReadLine()
    if ($null -eq $command) { Start-Sleep -Milliseconds 100; continue }
    if ($command -eq "quit") { exit 0 }
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

    Wait-ForCondition -TimeoutSeconds 20 -Failure "Concurrent managed hosts did not both reach ready state." -Condition {
        foreach ($serverId in @("one", "two")) {
            $statePath = Join-Path $managedRoot "$serverId\state.json"
            if (-not (Test-Path -LiteralPath $statePath)) { return $false }
            $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$state.status -ne "running") { return $false }
        }
        return $true
    }

    $events = @(Get-Content -LiteralPath $eventsPath -Encoding UTF8 | ForEach-Object { [string]$_ })
    $starts = @($events | Where-Object { $_ -like "java-start *" })
    $ready = @($events | Where-Object { $_ -like "ready *" })
    if ($starts.Count -ne 2 -or $ready.Count -ne 2) { throw "Unexpected startup event count." }
    $firstServer = ($starts[0] -split ' ')[1]
    $secondServer = ($starts[1] -split ' ')[1]
    $firstReadyIndex = [array]::FindIndex([string[]]$events, [Predicate[string]]{ param($line) $line -like "ready $firstServer *" })
    $secondStartIndex = [array]::FindIndex([string[]]$events, [Predicate[string]]{ param($line) $line -like "java-start $secondServer *" })
    if ($firstReadyIndex -lt 0 -or $secondStartIndex -le $firstReadyIndex) {
        throw "Shared startup lock allowed overlapping Java initialization."
    }

    [pscustomobject]@{
        ok = $true
        firstServer = $firstServer
        secondServer = $secondServer
        serialized = $true
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
    foreach ($hostProcess in $hostProcesses) {
        if ($hostProcess -and -not $hostProcess.HasExited) { Stop-Process -Id $hostProcess.Id -Force -ErrorAction SilentlyContinue }
    }
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $resolvedTempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if ($resolvedTestRoot.StartsWith($resolvedTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
