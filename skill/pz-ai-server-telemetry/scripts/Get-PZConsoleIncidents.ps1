param(
    [Parameter(Mandatory = $true)]
    [string]$ConsoleLog,

    [ValidateRange(1, 20)]
    [int]$MaxExamplesPerGroup = 4,

    [ValidateRange(0, 500)]
    [int]$TraceSearchLines = 80,

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

function Get-LineMetadata {
    param([string]$Line)

    if ($Line -match 'f:(?<frame>\d+)\s+st:(?<serverTime>[\d,]+)') {
        return [ordered]@{
            frame = [int64]$Matches.frame
            serverTime = [string]$Matches.serverTime
        }
    }
    return [ordered]@{ frame = $null; serverTime = $null }
}

function Get-AnonymizedConnection {
    param([string]$RawId)

    if ([string]::IsNullOrWhiteSpace($RawId)) { return $null }
    if (-not $script:connectionLabels.ContainsKey($RawId)) {
        $script:connectionLabels[$RawId] = 'Connection-{0:d2}' -f ($script:connectionLabels.Count + 1)
    }
    return [string]$script:connectionLabels[$RawId]
}

function Normalize-Signature {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return "unknown" }
    $value = $Text.Trim()
    $value = [regex]::Replace($value, '\b\d{7,}\b', '<id>')
    $value = [regex]::Replace($value, '\b-?\d+(?:\.\d+)?\b', '<n>')
    $value = [regex]::Replace($value, '\s+', ' ')
    if ($value.Length -gt 300) { $value = $value.Substring(0, 300) }
    return $value
}

function Get-NearestTrace {
    param(
        [int]$LineNumber,
        [ValidateSet("before", "after")][string]$Direction
    )

    $candidate = $null
    if ($Direction -eq "before") {
        $candidate = $script:traces |
            Where-Object { $_.lineNumber -lt $LineNumber -and ($LineNumber - $_.lineNumber) -le $TraceSearchLines } |
            Select-Object -Last 1
    } else {
        $candidate = $script:traces |
            Where-Object { $_.lineNumber -gt $LineNumber -and ($_.lineNumber - $LineNumber) -le $TraceSearchLines } |
            Select-Object -First 1
    }
    if ($null -eq $candidate) { return $null }
    return [ordered]@{
        lineNumber = [int]$candidate.lineNumber
        distanceLines = [math]::Abs([int]$candidate.lineNumber - $LineNumber)
        text = [string]$candidate.text
    }
}

function Get-FollowingEvidence {
    param([int]$Index)

    $exception = $null
    $objects = [Collections.Generic.List[object]]::new()
    $end = [math]::Min($script:runtimeLines.Count - 1, $Index + 18)
    for ($cursor = $Index + 1; $cursor -le $end; $cursor++) {
        $line = [string]$script:runtimeLines[$cursor]
        if ($cursor -gt ($Index + 1) -and $line -match '^ERROR:.*>\s*(?!Exception thrown)') { break }
        if ($null -eq $exception -and $line -match '^\s*(?<exception>(?:java\.|se\.|zombie\.).*?(?:Exception|Error).*|java\.lang\..*)$') {
            $exception = Normalize-Signature -Text $Matches.exception
        }
        if ($line -match 'ObjectModDataPacket\.parse: object is null.*"objectType"\s*:\s*(?<type>-?\d+),\s*"objectId"\s*:\s*(?<id>-?\d+),\s*"squareX"\s*:\s*(?<x>-?\d+),\s*"squareY"\s*:\s*(?<y>-?\d+),\s*"squareZ"\s*:\s*(?<z>-?\d+)') {
            $objects.Add([ordered]@{
                objectType = [int]$Matches.type
                objectId = [int]$Matches.id
                square = @([int]$Matches.x, [int]$Matches.y, [int]$Matches.z)
                lineNumber = $script:startLineNumber + $cursor
            })
        }
    }
    return [ordered]@{
        exception = $exception
        objects = @($objects)
    }
}

$resolvedLog = [IO.Path]::GetFullPath($ConsoleLog)
if (-not (Test-Path -LiteralPath $resolvedLog -PathType Leaf)) {
    throw "Dedicated Server console log was not found: $resolvedLog"
}

$allLines = @((Read-SharedUtf8Text -Path $resolvedLog) -split "`r?`n")
$startIndex = -1
for ($index = $allLines.Count - 1; $index -ge 0; $index--) {
    if ($allLines[$index].Contains('*** SERVER STARTED ****')) {
        $startIndex = $index
        break
    }
}
if ($startIndex -lt 0) { $startIndex = 0 }
$script:startLineNumber = $startIndex + 1
$script:runtimeLines = @($allLines[$startIndex..($allLines.Count - 1)])
$script:connectionLabels = @{}
$script:traces = @()

for ($index = 0; $index -lt $script:runtimeLines.Count; $index++) {
    $line = [string]$script:runtimeLines[$index]
    if ($line -match '\[PZCompatTrace\]\s*(?<text>.*)$') {
        $script:traces += [pscustomobject]@{
            lineNumber = $script:startLineNumber + $index
            text = $Matches.text
        }
    }
}

$incidents = [Collections.Generic.List[object]]::new()
$objectNullEvents = 0
$sanityCheckFailures = 0
$pzaiWarnings = 0
$spriteWarnings = @{}

for ($index = 0; $index -lt $script:runtimeLines.Count; $index++) {
    $line = [string]$script:runtimeLines[$index]
    $lineNumber = $script:startLineNumber + $index

    if ($line -match 'ObjectModDataPacket\.parse: object is null') { $objectNullEvents++ }
    if ($line -match 'SANITY CHECK FAIL') { $sanityCheckFailures++ }
    if ($line -match '\[PZAI\](?!_EVENT)') { $pzaiWarnings++ }
    if ($line -match 'Invalid SpriteConfig object! scripted object = (?<name>.+)$') {
        $name = $Matches.name.Trim()
        if (-not $spriteWarnings.ContainsKey($name)) { $spriteWarnings[$name] = 0 }
        $spriteWarnings[$name]++
    }

    $kind = $null
    $message = $null
    $connection = $null
    if ($line -match '^ERROR:.*Error with packet of type: ReceiveModData for (?<connection>\d+)\s*$') {
        $kind = "receive-mod-data-null-square"
        $message = "ReceiveModData referenced an unavailable square"
        $connection = Get-AnonymizedConnection -RawId $Matches.connection
    } elseif ($line -match '^ERROR:\s+Action.*NetTimedAction\.perform> Exception thrown') {
        $kind = "net-timed-action-null-return"
        $message = "NetTimedAction Lua callback returned no Boolean"
    } elseif ($line -match '^ERROR:.*>\s*(?<message>.+)$' -and $Matches.message -ne 'Exception thrown') {
        $kind = "other-error"
        $message = [string]$Matches.message
    }
    if ($null -eq $kind) { continue }

    $metadata = Get-LineMetadata -Line $line
    $evidence = Get-FollowingEvidence -Index $index
    $signatureSource = if ($evidence.exception) { $evidence.exception } else { $message }
    $signature = "${kind}:$(Normalize-Signature -Text $signatureSource)"
    $incidents.Add([pscustomobject][ordered]@{
        kind = $kind
        signature = $signature
        lineNumber = $lineNumber
        frame = $metadata.frame
        serverTime = $metadata.serverTime
        connection = $connection
        message = $message
        exception = $evidence.exception
        objectEvidence = @($evidence.objects)
        traceBefore = Get-NearestTrace -LineNumber $lineNumber -Direction before
        traceAfter = Get-NearestTrace -LineNumber $lineNumber -Direction after
    })
}

$groups = @()
foreach ($group in ($incidents | Group-Object signature | Sort-Object Count -Descending)) {
    $ordered = @($group.Group | Sort-Object lineNumber)
    $byConnection = [ordered]@{}
    foreach ($connectionGroup in ($ordered | Where-Object connection | Group-Object connection | Sort-Object Name)) {
        $byConnection[$connectionGroup.Name] = $connectionGroup.Count
    }
    $groups += [ordered]@{
        kind = [string]$ordered[0].kind
        signature = [string]$group.Name
        count = $group.Count
        firstLine = [int]$ordered[0].lineNumber
        lastLine = [int]$ordered[-1].lineNumber
        byConnection = $byConnection
        examples = @($ordered | Select-Object -First $MaxExamplesPerGroup)
    }
}

$spriteGroups = @($spriteWarnings.GetEnumerator() |
    Sort-Object Value -Descending |
    ForEach-Object { [ordered]@{ name = [string]$_.Key; count = [int]$_.Value } })

$result = [ordered]@{
    schema = "pzai.console-incidents/1"
    generatedAt = (Get-Date).ToString("o")
    source = [ordered]@{
        path = $resolvedLog
        scope = if ($startIndex -gt 0) { "after-latest-server-started-marker" } else { "whole-file-no-start-marker" }
        startLine = $script:startLineNumber
        endLine = $allLines.Count
        linesScanned = $script:runtimeLines.Count
    }
    counts = [ordered]@{
        primaryErrorIncidents = $incidents.Count
        receiveModDataNullSquare = @($incidents | Where-Object kind -eq "receive-mod-data-null-square").Count
        netTimedActionNullReturn = @($incidents | Where-Object kind -eq "net-timed-action-null-return").Count
        otherErrors = @($incidents | Where-Object kind -eq "other-error").Count
        objectModDataNull = $objectNullEvents
        sanityCheckFailures = $sanityCheckFailures
        pzaiWarnings = $pzaiWarnings
        pzCompatTraceLines = $script:traces.Count
    }
    groups = $groups
    spriteConfigWarnings = $spriteGroups
    notes = @(
        "Counts use primary error headers, not repeated exception or stack lines.",
        "Connection identifiers are report-local anonymous labels.",
        "Nearby PZCompatTrace records are temporal evidence only and do not prove causation."
    )
}

$json = $result | ConvertTo-Json -Depth 20 -Compress:$Compact
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::WriteLine($json)
