param(
    [Parameter(Mandatory = $true)][string]$ServerName,
    [ValidateRange(2, 3600)][int]$DurationSeconds = 60,
    [ValidateRange(1, 300)][int]$IntervalSeconds = 5,
    [switch]$Compact
)

$ErrorActionPreference = 'Stop'
$strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
if ($IntervalSeconds -gt $DurationSeconds) { throw 'IntervalSeconds cannot exceed DurationSeconds.' }

function Read-SharedRange {
    param([string]$Path, [long]$Offset)

    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $reset = $stream.Length -lt $Offset
        if ($reset) { $Offset = 0 }
        [void]$stream.Seek($Offset, [IO.SeekOrigin]::Begin)
        $reader = [IO.StreamReader]::new($stream, $strictUtf8, $true, 4096, $true)
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
        return [ordered]@{ text = $text; endOffset = $stream.Length; reset = $reset }
    } finally { $stream.Dispose() }
}

$inventoryRaw = & (Join-Path $PSScriptRoot 'Get-PZServerInventory.ps1') -ServerName $ServerName -Compact | Out-String
$inventory = $inventoryRaw | ConvertFrom-Json
if ([int]$inventory.count -ne 1) { throw "Expected exactly one running server named '$ServerName'; found $($inventory.count)." }
$server = $inventory.servers | Select-Object -First 1
$logPath = [string]$server.consoleLog
if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) { throw "Console log not found: $logPath" }

$process = Get-Process -Id ([int]$server.pid) -ErrorAction Stop
$startOffset = (Get-Item -LiteralPath $logPath).Length
$startedAt = Get-Date
$lastAt = $startedAt
$lastCpu = $process.TotalProcessorTime.TotalSeconds
$samples = @()

while (((Get-Date) - $startedAt).TotalSeconds -lt $DurationSeconds) {
    $remaining = $DurationSeconds - [int][math]::Floor(((Get-Date) - $startedAt).TotalSeconds)
    Start-Sleep -Seconds ([math]::Min($IntervalSeconds, [math]::Max(1, $remaining)))
    $now = Get-Date
    $process = Get-Process -Id ([int]$server.pid) -ErrorAction Stop
    $elapsed = ($now - $lastAt).TotalSeconds
    $cpuNow = $process.TotalProcessorTime.TotalSeconds
    $cores = if ($elapsed -gt 0) { ($cpuNow - $lastCpu) / $elapsed } else { 0 }
    $samples += [ordered]@{
        time = $now.ToString('o')
        cpuCores = [math]::Round($cores, 3)
        hostCpuPercent = [math]::Round(($cores / [math]::Max(1, [int]$server.logicalProcessors)) * 100, 2)
        workingSetMB = [math]::Round($process.WorkingSet64 / 1MB, 2)
        privateMemoryMB = [math]::Round($process.PrivateMemorySize64 / 1MB, 2)
        threadCount = $process.Threads.Count
        handleCount = $process.HandleCount
        consoleBytes = (Get-Item -LiteralPath $logPath).Length
    }
    $lastAt = $now
    $lastCpu = $cpuNow
}

$delta = Read-SharedRange -Path $logPath -Offset $startOffset
$lines = @([string]$delta.text -split "`r?`n")
$patterns = [ordered]@{
    serverTooBusy = 'Server is too busy'
    primaryErrors = '^ERROR:'
    invalidSpriteConfig = 'Invalid SpriteConfig object!'
    objectModDataNull = 'ObjectModDataPacket\.parse: object is null'
    packetStateLimit = 'Packets limit has exceeded for State'
    duplicateEntityRegistration = 'Entity is already registered'
    duplicateContainerItemId = 'ItemContainer\.AddItem: container already has id'
    stackOverflow = 'StackOverflowError'
    itemPickInfo = 'ItemPickInfo.*cannot get ID'
    agentRefused = 'REFUSED unsupported'
}
$counts = [ordered]@{}
foreach ($entry in $patterns.GetEnumerator()) { $counts[$entry.Key] = @($lines | Select-String -Pattern $entry.Value).Count }

$errorGroups = @($lines | Where-Object { $_ -match '^ERROR:' } | ForEach-Object {
    [regex]::Replace([regex]::Replace($_.Trim(), '\b\d{5,}\b', '<id>'), '\s+', ' ')
} | Group-Object | Sort-Object Count -Descending | Select-Object -First 12 | ForEach-Object {
    [ordered]@{ signature = $_.Name; count = $_.Count }
})

$result = [ordered]@{
    schema = 'pz-server-health-watch/1'
    serverName = [string]$server.serverName
    pid = [int]$server.pid
    startedAt = $startedAt.ToString('o')
    endedAt = (Get-Date).ToString('o')
    durationSeconds = [math]::Round(((Get-Date) - $startedAt).TotalSeconds, 2)
    intervalSeconds = $IntervalSeconds
    log = [ordered]@{
        path = $logPath
        startOffset = $startOffset
        endOffset = [long]$delta.endOffset
        rotatedOrTruncated = [bool]$delta.reset
        bytesObserved = [Text.Encoding]::UTF8.GetByteCount([string]$delta.text)
        linesObserved = $lines.Count
        counts = $counts
        topErrorHeaders = $errorGroups
    }
    samples = $samples
    notes = @(
        'CPU cores is process CPU-seconds divided by wall-seconds; host percent divides that by logical processor count.',
        'Only log bytes appended during this observation are classified.',
        'This watcher does not identify packet payloads or per-thread Java stacks.'
    )
}

[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Write-Output ($result | ConvertTo-Json -Depth 15 -Compress:$Compact)
