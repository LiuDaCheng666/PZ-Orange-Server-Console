param(
    [Parameter(Mandatory = $true)]
    [string]$CacheDir,

    [string]$ConsoleLog,

    [switch]$Compact
)

$ErrorActionPreference = "Stop"
$strictUtf8 = [Text.UTF8Encoding]::new($false, $true)

function Read-SharedUtf8Text {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [IO.File]::Open(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite
    )
    $reader = [IO.StreamReader]::new($stream, $strictUtf8, $true)
    try { return $reader.ReadToEnd() }
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Get-PropertyValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

$resolvedCacheDir = [IO.Path]::GetFullPath($CacheDir)
$luaDir = Join-Path $resolvedCacheDir "Lua"
$statePath = Join-Path $luaDir "PZAI-session-state.ini"
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    throw "PZAI session state was not found: $statePath"
}

$state = @{}
foreach ($line in (Read-SharedUtf8Text -Path $statePath) -split "`r?`n") {
    if ($line -match '^([^=]+)=(.*)$') { $state[$Matches[1].Trim()] = $Matches[2].Trim() }
}
$slot = 0
if (-not [int]::TryParse([string]$state.slot, [ref]$slot) -or $slot -lt 1 -or $slot -gt 10) {
    throw "Invalid active PZAI session slot in $statePath"
}

$eventPath = Join-Path $luaDir "PZAI-session-$slot-events.log"
if (-not (Test-Path -LiteralPath $eventPath -PathType Leaf)) {
    throw "Active PZAI event log was not found: $eventPath"
}

$events = [Collections.Generic.List[object]]::new()
$invalidLines = 0
foreach ($line in (Read-SharedUtf8Text -Path $eventPath) -split "`r?`n") {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $events.Add(($line | ConvertFrom-Json)) }
    catch { $invalidLines++ }
}
if ($events.Count -eq 0) { throw "The active PZAI event log contains no valid events." }

$first = $events[0]
$last = $events[$events.Count - 1]
$durationMs = [math]::Max(0, [double]$last.timestampMs - [double]$first.timestampMs)
$durationMinutes = $durationMs / 60000.0
$eventBytes = (Get-Item -LiteralPath $eventPath).Length

$eventCounts = [ordered]@{}
foreach ($group in ($events | Group-Object type | Sort-Object Name)) {
    $eventCounts[$group.Name] = $group.Count
}

$performance = @()
foreach ($group in ($events | Where-Object type -eq "client.performance" | Group-Object { $_.actor.username })) {
    $fps = @($group.Group | ForEach-Object { [double]$_.data.preferredFps })
    $performance += [ordered]@{
        player = $group.Name
        samples = $fps.Count
        minimumFps = ($fps | Measure-Object -Minimum).Minimum
        averageFps = [math]::Round(($fps | Measure-Object -Average).Average, 1)
        maximumFps = ($fps | Measure-Object -Maximum).Maximum
        sources = @(($group.Group | ForEach-Object { $_.data.preferredFpsSource }) | Sort-Object -Unique)
    }
}

$heartbeats = @($events | Where-Object type -eq "server.heartbeat")
$latestHeartbeat = if ($heartbeats.Count -gt 0) { $heartbeats[-1] } else { $null }
$heartbeatDelays = @($heartbeats | ForEach-Object { [double]$_.data.timing.heartbeatDelayMs })
$protocol = if ($latestHeartbeat) { $latestHeartbeat.data.protocol } else { $null }
$logStore = if ($latestHeartbeat) { $latestHeartbeat.data.logStore } else { $null }

$diagnostics = @()
foreach ($request in ($events | Where-Object type -eq "agent.request" | Where-Object { $_.data.kind -eq "diagnose" })) {
    $requestId = [string](Get-PropertyValue -Object $request.data -Name "requestId")
    $category = [string]$request.data.category
    $actor = [string]$request.actor.username
    $expectedServerValue = Get-PropertyValue -Object $request.data -Name "expectedServerSnapshot"
    $expectedClientValue = Get-PropertyValue -Object $request.data -Name "expectedClientSnapshot"
    $expectedServer = if ($null -eq $expectedServerValue) { $null } else { [bool]$expectedServerValue }
    $expectedClient = if ($null -eq $expectedClientValue) { $null } else { [bool]$expectedClientValue }
    $matching = @()
    $legacyCandidates = @()
    if (-not [string]::IsNullOrWhiteSpace($requestId)) {
        $matching = @($events | Where-Object {
            $_.type -eq "diagnostic.snapshot" -and
            [string](Get-PropertyValue -Object $_.data -Name "requestId") -eq $requestId -and
            [string]$_.sessionId -eq [string]$request.sessionId -and
            [string]$_.actor.username -eq $actor -and
            [string]$_.data.category -eq $category
        })
    } else {
        $legacyCandidates = @($events | Where-Object {
            $_.type -eq "diagnostic.snapshot" -and
            [string]$_.sessionId -eq [string]$request.sessionId -and
            [string]$_.actor.username -eq $actor -and
            [string]$_.data.category -eq $category -and
            [double]$_.timestampMs -ge [double]$request.timestampMs -and
            [double]$_.timestampMs -le ([double]$request.timestampMs + 5000)
        })
    }
    $serverMatches = @($matching | Where-Object { $_.data.source -eq "server" })
    $clientMatches = @($matching | Where-Object { $_.data.source -eq "client" })
    $unexpectedMatches = @($matching | Where-Object { $_.data.source -ne "server" -and $_.data.source -ne "client" })
    $modernRequest = -not [string]::IsNullOrWhiteSpace($requestId)
    $expectationsKnown = $null -ne $expectedServer -and $null -ne $expectedClient
    $complete = $false
    if ($modernRequest -and $expectationsKnown -and $unexpectedMatches.Count -eq 0) {
        $serverComplete = if ($expectedServer) { $serverMatches.Count -eq 1 } else { $serverMatches.Count -eq 0 }
        $clientComplete = if ($expectedClient) { $clientMatches.Count -eq 1 } else { $clientMatches.Count -eq 0 }
        $complete = $serverComplete -and $clientComplete
    }
    $diagnostics += [ordered]@{
        actor = $actor
        category = $category
        requestId = if ($requestId) { $requestId } else { $null }
        expectedServerSnapshot = $expectedServer
        expectedClientSnapshot = $expectedClient
        serverPresent = $serverMatches.Count -eq 1
        clientPresent = $clientMatches.Count -eq 1
        snapshots = @($matching | ForEach-Object {
            [ordered]@{
                source = [string](Get-PropertyValue -Object $_.data -Name "source")
                eventId = [string]$_.eventId
                timestampMs = [double]$_.timestampMs
            }
        })
        legacyCandidates = @($legacyCandidates | ForEach-Object {
            $source = [string](Get-PropertyValue -Object $_.data -Name "source")
            [ordered]@{
                source = if ($source) { $source } else { "unspecified" }
                requestId = Get-PropertyValue -Object $_.data -Name "requestId"
                eventId = [string]$_.eventId
                timestampMs = [double]$_.timestampMs
            }
        })
        complete = $complete
        correlationStatus = if (-not $modernRequest) {
            "legacy-unverifiable"
        } elseif (-not $expectationsKnown) {
            "expectations-missing"
        } elseif ($complete) {
            "complete"
        } else {
            "incomplete"
        }
        legacyCorrelation = -not $modernRequest
    }
}

$consoleSummary = $null
if ([string]::IsNullOrWhiteSpace($ConsoleLog)) {
    $candidate = Join-Path $resolvedCacheDir "server-console.txt"
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $ConsoleLog = $candidate }
}
if (-not [string]::IsNullOrWhiteSpace($ConsoleLog) -and
        (Test-Path -LiteralPath $ConsoleLog -PathType Leaf)) {
    $consoleText = Read-SharedUtf8Text -Path $ConsoleLog
    $marker = "*** SERVER STARTED ****"
    $startIndex = $consoleText.LastIndexOf($marker, [StringComparison]::Ordinal)
    $runtimeText = if ($startIndex -ge 0) { $consoleText.Substring($startIndex) } else { $consoleText }
    $patterns = [ordered]@{
        errors = 'ERROR'
        exceptions = 'Exception'
        sanityCheckFailures = 'SANITY CHECK FAIL'
        receiveModDataNullSquare = 'ReceiveModDataPacket.processServer'
        objectModDataNull = 'ObjectModDataPacket.parse object null'
        invalidSpriteConfig = 'Invalid SpriteConfig'
        timedActionFailures = 'NetTimedAction.perform'
        pzaiPipelineWarnings = '[PZAI]'
    }
    $counts = [ordered]@{}
    foreach ($entry in $patterns.GetEnumerator()) {
        $counts[$entry.Key] = [regex]::Matches(
            $runtimeText,
            [regex]::Escape([string]$entry.Value),
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        ).Count
    }
    $consoleSummary = [ordered]@{
        path = [IO.Path]::GetFullPath($ConsoleLog)
        scope = if ($startIndex -ge 0) { "after-latest-server-started-marker" } else { "whole-file-no-start-marker" }
        bytesScanned = $strictUtf8.GetByteCount($runtimeText)
        counts = $counts
    }
}

$result = [ordered]@{
    schema = "pzai.session-summary/1"
    generatedAt = (Get-Date).ToString("o")
    instance = [ordered]@{
        cacheDir = $resolvedCacheDir
        sessionState = $statePath
        eventLog = $eventPath
        slot = $slot
        configuredSlots = [int]$state.slots
        sessionId = [string]$state.sessionId
    }
    window = [ordered]@{
        firstTimestampMs = [double]$first.timestampMs
        lastTimestampMs = [double]$last.timestampMs
        durationMinutes = [math]::Round($durationMinutes, 2)
        validEvents = $events.Count
        invalidJsonLines = $invalidLines
        bytes = $eventBytes
        eventsPerMinute = if ($durationMinutes -gt 0) { [math]::Round($events.Count / $durationMinutes, 2) } else { $null }
        bytesPerMinute = if ($durationMinutes -gt 0) { [math]::Round($eventBytes / $durationMinutes, 1) } else { $null }
    }
    eventCounts = $eventCounts
    players = [ordered]@{
        joined = @($events | Where-Object type -eq "player.joined" | ForEach-Object { $_.actor.username } | Sort-Object -Unique)
        latestOnlineCount = if ($latestHeartbeat) { [int]$latestHeartbeat.data.onlinePlayers } else { $null }
        performance = $performance
    }
    health = [ordered]@{
        heartbeatSamples = $heartbeats.Count
        heartbeatDelayAverageMs = if ($heartbeatDelays.Count) { [math]::Round(($heartbeatDelays | Measure-Object -Average).Average, 1) } else { $null }
        heartbeatDelayMaximumMs = if ($heartbeatDelays.Count) { ($heartbeatDelays | Measure-Object -Maximum).Maximum } else { $null }
        logActive = Get-PropertyValue -Object $logStore -Name "active"
        logWriteFailures = Get-PropertyValue -Object $logStore -Name "writeFailures"
        protocolFailures = [ordered]@{
            callback = Get-PropertyValue -Object $protocol -Name "callbackFailures"
            clientProvider = Get-PropertyValue -Object $protocol -Name "clientProviderFailures"
            enricher = Get-PropertyValue -Object $protocol -Name "enricherFailures"
            listener = Get-PropertyValue -Object $protocol -Name "listenerFailures"
            provider = Get-PropertyValue -Object $protocol -Name "providerFailures"
            sink = Get-PropertyValue -Object $protocol -Name "sinkFailures"
            rejections = Get-PropertyValue -Object $protocol -Name "protocolRejections"
            truncatedEvents = Get-PropertyValue -Object $protocol -Name "eventsTruncated"
            recent = @(Get-PropertyValue -Object $protocol -Name "recentFailures")
        }
    }
    diagnostics = $diagnostics
    consoleRuntime = $consoleSummary
}

$depth = if ($Compact) { 12 } else { 20 }
$json = $result | ConvertTo-Json -Depth $depth -Compress:$Compact
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Write-Output $json
