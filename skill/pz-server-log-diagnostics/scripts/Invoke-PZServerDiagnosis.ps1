param(
    [string]$ServerName,
    [string]$CacheDir,
    [string]$ConsoleLog,
    [ValidateRange(0, 60)][int]$SampleSeconds = 0,
    [ValidateRange(1, 50)][int]$MaxGroups = 15,
    [switch]$Compact
)

$ErrorActionPreference = 'Stop'
$scriptRoot = $PSScriptRoot
$strictUtf8 = [Text.UTF8Encoding]::new($false, $true)

function Read-SharedUtf8Text {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $reader = [IO.StreamReader]::new($stream, $strictUtf8, $true)
    try { return $reader.ReadToEnd() }
    finally { $reader.Dispose(); $stream.Dispose() }
}

function Get-PatternSummary {
    param([string[]]$Lines)

    $patterns = [ordered]@{
        serverTooBusy = 'Server is too busy'
        invalidSpriteConfig = 'Invalid SpriteConfig object!'
        objectModDataNull = 'ObjectModDataPacket\.parse: object is null'
        packetStateLimit = 'Packets limit has exceeded for State'
        itemPickInventoryMale = 'cannot get ID for container:\s*inventorymale'
        itemPickInventoryFemale = 'cannot get ID for container:\s*inventoryfemale'
        duplicateEntityRegistration = 'Entity is already registered'
        duplicateContainerItemId = 'ItemContainer\.AddItem: container already has id'
        stackOverflow = 'StackOverflowError'
        timedActionException = 'NetTimedAction\.perform> Exception thrown'
        formatConversion = 'UnknownFormatConversionException'
        animatorProbeFailure = 'AdvancedAnimator\.visitFileFailed'
        writerUnavailable = 'writer_unavailable'
        pzStreamingDiagnostics = '\[PZStreaming\].*diagnostic interval'
        agentRefused = '\bREFUSED unsupported\b'
    }
    $summary = [ordered]@{}
    foreach ($entry in $patterns.GetEnumerator()) {
        $summary[$entry.Key] = @($Lines | Select-String -Pattern $entry.Value).Count
    }
    return $summary
}

function Get-AgentVerification {
    param([object[]]$Agents, [string[]]$Lines, [string]$ConfiguredArguments)

    $definitions = [ordered]@{
        'OrangeAntiCheat-agent.jar' = [ordered]@{ prefix = '\[OrangeAntiCheat\]'; active = '\[OrangeAntiCheat\].*(agent_installed|guard_ready)' }
        'PZServerStreamingStability-agent.jar' = [ordered]@{ prefix = '\[PZStreaming\]'; active = '\[PZStreaming\].*ACTIVE' }
        'PZGlassRemovalGuard-agent.jar' = [ordered]@{ prefix = '\[PZGlassRemovalGuard\]'; active = '\[PZGlassRemovalGuard\].*ACTIVE' }
        'PZItemContainerCycleGuard-agent.jar' = [ordered]@{ prefix = '\[PZItemContainerCycleGuard\]'; active = '\[PZItemContainerCycleGuard\].*ACTIVE' }
        'PZEntityRegistrationGuard-agent.jar' = [ordered]@{ prefix = '\[PZEntityRegistrationGuard\]'; active = '\[PZEntityRegistrationGuard\].*ACTIVE' }
        'PZItemPickInfoContainerFix-agent.jar' = [ordered]@{ prefix = '\[PZItemPickInfoContainerFix\]'; active = '\[PZItemPickInfoContainerFix\].*ACTIVE' }
        'PZTimedActionIsolationFix-agent.jar' = [ordered]@{ prefix = '\[PZTimedActionIsolationFix\]'; active = '\[PZTimedActionIsolationFix\].*ACTIVE' }
        'PZSpriteConfigAliasPatch-agent.jar' = [ordered]@{ prefix = '\[PZSpriteAlias\]'; active = '\[PZSpriteAlias\].*ACTIVE' }
    }
    $result = @()
    foreach ($agent in $Agents) {
        $name = [string]$agent.name
        $definition = $definitions[$name]
        $activePattern = if ($definition) { [string]$definition.active } else { $null }
        $prefixPattern = if ($definition) { [string]$definition.prefix } else { '\[' + [regex]::Escape([IO.Path]::GetFileNameWithoutExtension($name).Replace('-agent', '')) + '\]' }
        $activeLines = if ($activePattern) { @($Lines | Select-String -Pattern $activePattern | Select-Object -First 6 | ForEach-Object { $_.Line }) } else { @() }
        $refusedLines = @($Lines | Select-String -Pattern ($prefixPattern + '.*REFUSED') | Select-Object -First 6 | ForEach-Object { $_.Line })
        $result += [ordered]@{
            name = $name
            mountedInCurrentJvm = $true
            configuredForNextManagedStart = -not [string]::IsNullOrWhiteSpace($ConfiguredArguments) -and $ConfiguredArguments.IndexOf($name, [StringComparison]::OrdinalIgnoreCase) -ge 0
            filePresent = [bool]$agent.filePresent
            activeObservedInConsole = $activeLines.Count -gt 0
            refusedObservedInConsole = $refusedLines.Count -gt 0
            activeEvidence = $activeLines
            refusedEvidence = $refusedLines
            note = if ($refusedLines.Count -gt 0) {
                'Target transform was refused; target class remained vanilla.'
            } elseif ($activeLines.Count -gt 0) {
                'ACTIVE evidence was observed in this console scope.'
            } else {
                'Mounted in the current JVM; no ACTIVE line was retained in this PZ console scope.'
            }
        }
    }
    return @($result)
}

$inventoryArgs = @{}
if ($ServerName) { $inventoryArgs.ServerName = $ServerName }
if ($CacheDir) { $inventoryArgs.CacheDir = $CacheDir }
$inventoryRaw = & (Join-Path $scriptRoot 'Get-PZServerInventory.ps1') @inventoryArgs -Compact | Out-String
$inventory = $inventoryRaw | ConvertFrom-Json

if (-not $ConsoleLog) {
    if ([int]$inventory.count -eq 0) { throw 'No running server matched. Supply -ConsoleLog for offline analysis or verify -ServerName/-CacheDir.' }
    if ([int]$inventory.count -gt 1) { throw 'More than one running server matched. Supply an exact -ServerName or -CacheDir.' }
    $selected = $inventory.servers | Select-Object -First 1
    $ConsoleLog = [string]$selected.consoleLog
} else {
    $selected = if ([int]$inventory.count -eq 1) { $inventory.servers | Select-Object -First 1 } else { $null }
}

$resolvedLog = [IO.Path]::GetFullPath($ConsoleLog)
if (-not (Test-Path -LiteralPath $resolvedLog -PathType Leaf)) { throw "Console log not found: $resolvedLog" }

$text = Read-SharedUtf8Text -Path $resolvedLog
$allLines = @($text -split "`r?`n")
$startIndex = -1
for ($index = $allLines.Count - 1; $index -ge 0; $index--) {
    if ($allLines[$index].Contains('*** SERVER STARTED ****')) { $startIndex = $index; break }
}
$scopeLines = if ($startIndex -ge 0) { @($allLines[$startIndex..($allLines.Count - 1)]) } else { $allLines }

$incidentRaw = & (Join-Path $scriptRoot 'Get-PZConsoleIncidents.ps1') -ConsoleLog $resolvedLog -MaxExamplesPerGroup 3 -Compact | Out-String
$incidents = $incidentRaw | ConvertFrom-Json
$topGroups = @($incidents.groups | Select-Object -First $MaxGroups)
$spriteGroups = @($incidents.spriteConfigWarnings | Select-Object -First $MaxGroups)

$processSample = $null
if ($selected -and $SampleSeconds -gt 0) {
    $beforeProcess = Get-Process -Id ([int]$selected.pid) -ErrorAction Stop
    $beforeCpu = $beforeProcess.TotalProcessorTime.TotalSeconds
    $beforeLength = (Get-Item -LiteralPath $resolvedLog).Length
    $sampleStarted = Get-Date
    Start-Sleep -Seconds $SampleSeconds
    $afterProcess = Get-Process -Id ([int]$selected.pid) -ErrorAction Stop
    $elapsed = ((Get-Date) - $sampleStarted).TotalSeconds
    $cpuCores = if ($elapsed -gt 0) { ($afterProcess.TotalProcessorTime.TotalSeconds - $beforeCpu) / $elapsed } else { 0 }
    $logical = [math]::Max(1, [int]$selected.logicalProcessors)
    $afterLength = (Get-Item -LiteralPath $resolvedLog).Length
    $processSample = [ordered]@{
        durationSeconds = [math]::Round($elapsed, 3)
        averageCpuCores = [math]::Round($cpuCores, 3)
        averageHostCpuPercent = [math]::Round(($cpuCores / $logical) * 100, 2)
        workingSetMB = [math]::Round($afterProcess.WorkingSet64 / 1MB, 2)
        privateMemoryMB = [math]::Round($afterProcess.PrivateMemorySize64 / 1MB, 2)
        consoleBytesAdded = [math]::Max(0, $afterLength - $beforeLength)
    }
}

$result = [ordered]@{
    schema = 'pz-server-diagnosis/1'
    generatedAt = (Get-Date).ToString('o')
    selectedInstance = if ($selected) {
        [ordered]@{
            serverName = [string]$selected.serverName
            pid = [int]$selected.pid
            processCreatedAt = [string]$selected.processCreatedAt
            cacheDir = [string]$selected.cacheDir
            runtimeRoot = [string]$selected.runtimeRoot
            xms = [string]$selected.xms
            xmx = [string]$selected.xmx
        }
    } else { $null }
    source = [ordered]@{
        consoleLog = $resolvedLog
        scope = if ($startIndex -ge 0) { 'after-latest-server-started-marker' } else { 'whole-file-no-start-marker' }
        startLine = if ($startIndex -ge 0) { $startIndex + 1 } else { 1 }
        endLine = $allLines.Count
        linesScanned = $scopeLines.Count
        fileBytes = (Get-Item -LiteralPath $resolvedLog).Length
    }
    patternCounts = Get-PatternSummary -Lines $scopeLines
    topIncidentGroups = $topGroups
    topSpriteConfigGroups = $spriteGroups
    agentStatus = if ($selected) {
        @(Get-AgentVerification -Agents @($selected.javaAgents) -Lines $scopeLines -ConfiguredArguments ([string]$selected.managedProfile.configuredArguments))
    } else { @() }
    processSample = $processSample
    interpretationWarnings = @(
        'Counts are restricted to the latest startup marker when present.',
        'Server is too busy is a symptom, not a root cause.',
        'A JVM command-line Agent without retained ACTIVE output is mounted but not console-verified.',
        'Nearby player or Mod evidence does not by itself prove ownership or successful mutation.'
    )
}

[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Write-Output ($result | ConvertTo-Json -Depth 20 -Compress:$Compact)
