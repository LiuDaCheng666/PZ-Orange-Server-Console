$script:PZAIQueueUtf8 = [Text.UTF8Encoding]::new($false, $true)
$script:PZAIQueueManifestName = "PZAI-agent-response-manifest.ini"
$script:PZAIQueueAckName = "PZAI-agent-response-ack.ini"
$script:PZAIQueueLegacyName = "PZAI-agent-response-queue.txt"
$script:PZAIQueueStateName = "PZAI-agent-response-state.ini"
$script:PZAIQueueMaxBytes = 1MB
$script:PZAIQueueMaxLines = 2000
$script:PZAIQueueMaxPayloadBytes = 16384
$script:PZAIQueueMaxLineBytes = 24576

function ConvertTo-PZAIQueueEnvelope {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Payload,
        [switch]$AllowInvalidLegacyPayload
    )

    if ($Payload.IndexOf("`r") -ge 0 -or $Payload.IndexOf("`n") -ge 0) {
        throw "Queue payload must be exactly one logical line."
    }
    $bytes = $script:PZAIQueueUtf8.GetBytes($Payload)
    if (-not $AllowInvalidLegacyPayload -and
            ($bytes.Length -eq 0 -or $bytes.Length -gt $script:PZAIQueueMaxPayloadBytes)) {
        throw "Queue payload exceeds the 16384-byte protocol limit."
    }
    $base64 = [Convert]::ToBase64String($bytes)
    return '{"schema":"pzai.agent-response-record/2","encoding":"base64","payload":"' +
        $base64 + '"}'
}

function Write-PZAIAtomicUtf8 {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        throw "Queue directory does not exist: $directory"
    }
    $temp = Join-Path $directory ((Split-Path -Leaf $Path) + "." +
        [guid]::NewGuid().ToString("N") + ".tmp")
    $stream = $null
    try {
        $bytes = $script:PZAIQueueUtf8.GetBytes($Text)
        $stream = [IO.FileStream]::new($temp, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::None)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $backup = $Path + "." + [guid]::NewGuid().ToString("N") + ".bak"
            try { [IO.File]::Replace($temp, $Path, $backup, $true) }
            finally { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
        }
        else {
            [IO.File]::Move($temp, $Path)
        }
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

function Read-PZAIIni {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $result = @{}
    try {
        foreach ($line in [IO.File]::ReadAllLines($Path, $script:PZAIQueueUtf8)) {
            if ($line -match '^([A-Za-z][A-Za-z0-9]*)=(.*)$') {
                $result[$Matches[1]] = $Matches[2]
            }
        }
    }
    catch { return $null }
    return $result
}

function Get-PZAIQueueFilename {
    param([Parameter(Mandatory)][long]$Generation)
    return "PZAI-agent-response-queue-g{0:D12}.jsonl" -f $Generation
}

function Test-PZAIQueueFilename {
    param([AllowEmptyString()][string]$Filename)
    return $Filename -match '^PZAI-agent-response-queue-g[0-9]{12}\.jsonl$'
}

function Get-PZAIQueueManifest {
    param([Parameter(Mandatory)][string]$LuaDir)

    $values = Read-PZAIIni -Path (Join-Path $LuaDir $script:PZAIQueueManifestName)
    if ($null -eq $values -or $values.schema -ne 'pzai.agent-response-manifest/2') {
        return $null
    }
    $generation = 0L
    $publishedLines = 0L
    $legacyBaseCursor = 0L
    if (-not [long]::TryParse([string]$values.generation, [ref]$generation) -or
            $generation -lt 1 -or
            -not [long]::TryParse([string]$values.publishedLines, [ref]$publishedLines) -or
            $publishedLines -lt 0 -or
            -not [long]::TryParse([string]$values.legacyBaseCursor, [ref]$legacyBaseCursor) -or
            $legacyBaseCursor -lt 0 -or
            -not (Test-PZAIQueueFilename -Filename ([string]$values.filename))) {
        return $null
    }
    return [pscustomobject]@{
        generation = $generation
        filename = [string]$values.filename
        publishedLines = $publishedLines
        legacyBaseCursor = $legacyBaseCursor
    }
}

function Publish-PZAIQueueManifest {
    param(
        [Parameter(Mandatory)][string]$LuaDir,
        [Parameter(Mandatory)][long]$Generation,
        [Parameter(Mandatory)][string]$Filename,
        [Parameter(Mandatory)][long]$PublishedLines,
        [Parameter(Mandatory)][long]$LegacyBaseCursor
    )

    if (-not (Test-PZAIQueueFilename -Filename $Filename)) {
        throw "Unsafe queue filename: $Filename"
    }
    $text = "schema=pzai.agent-response-manifest/2`n" +
        "generation=$Generation`nfilename=$Filename`n" +
        "publishedLines=$PublishedLines`nlegacyBaseCursor=$LegacyBaseCursor`n"
    Write-PZAIAtomicUtf8 -Path (Join-Path $LuaDir $script:PZAIQueueManifestName) -Text $text
}

function Get-PZAIQueueAck {
    param([Parameter(Mandatory)][string]$LuaDir)

    $values = Read-PZAIIni -Path (Join-Path $LuaDir $script:PZAIQueueAckName)
    if ($null -eq $values -or $values.schema -ne 'pzai.agent-response-ack/2') { return $null }
    $generation = 0L
    $cursor = 0L
    if (-not [long]::TryParse([string]$values.generation, [ref]$generation) -or
            $generation -lt 1 -or
            -not [long]::TryParse([string]$values.cursor, [ref]$cursor) -or
            $cursor -lt 0 -or
            -not (Test-PZAIQueueFilename -Filename ([string]$values.filename))) {
        return $null
    }
    return [pscustomobject]@{
        generation = $generation
        filename = [string]$values.filename
        cursor = $cursor
    }
}

function Get-PZAICompleteLineInfo {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ lines = @(); lineCount = 0L; completeBytes = 0L; fileBytes = 0L }
    }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $lastLf = [Array]::LastIndexOf($bytes, [byte]10)
    if ($lastLf -lt 0) {
        return [pscustomobject]@{ lines = @(); lineCount = 0L; completeBytes = 0L; fileBytes = [long]$bytes.Length }
    }
    $text = $script:PZAIQueueUtf8.GetString($bytes, 0, $lastLf + 1)
    $lines = @($text -split "`n")
    if ($lines.Count -gt 0 -and $lines[-1] -eq '') {
        if ($lines.Count -eq 1) { $lines = @() }
        else { $lines = @($lines[0..($lines.Count - 2)]) }
    }
    $lines = @($lines | ForEach-Object { $_.TrimEnd("`r") })
    return [pscustomobject]@{
        lines = $lines
        lineCount = [long]$lines.Count
        completeBytes = [long]($lastLf + 1)
        fileBytes = [long]$bytes.Length
    }
}

function Get-PZAILegacyCursor {
    param([Parameter(Mandatory)][string]$LuaDir)

    $values = Read-PZAIIni -Path (Join-Path $LuaDir $script:PZAIQueueStateName)
    $cursor = 0L
    $cursorValue = if ($null -ne $values -and
            $values.schema -eq 'pzai.agent-response-state/2') {
        $values.legacyCursor
    }
    elseif ($null -ne $values) { $values.cursor }
    else { $null }
    if ([long]::TryParse([string]$cursorValue, [ref]$cursor) -and $cursor -ge 0) {
        return $cursor
    }
    return 0L
}

function Get-PZAINextGeneration {
    param([Parameter(Mandatory)][string]$LuaDir)

    $maximum = 0L
    foreach ($file in @(Get-ChildItem -LiteralPath $LuaDir -File `
            -Filter 'PZAI-agent-response-queue-g*.jsonl' -ErrorAction SilentlyContinue)) {
        if ($file.Name -match '^PZAI-agent-response-queue-g([0-9]{12})\.jsonl$') {
            $value = [long]$Matches[1]
            if ($value -gt $maximum) { $maximum = $value }
        }
    }
    if ($maximum -ge 999999999999L) { throw "Queue generation space exhausted." }
    return $maximum + 1
}

function New-PZAIQueueGeneration {
    param(
        [Parameter(Mandatory)][string]$LuaDir,
        [Parameter(Mandatory)][long]$Generation,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$InitialLines,
        [Parameter(Mandatory)][long]$LegacyBaseCursor
    )

    $filename = Get-PZAIQueueFilename -Generation $Generation
    $path = Join-Path $LuaDir $filename
    if (Test-Path -LiteralPath $path) { throw "Queue generation already exists: $filename" }
    $text = if ($InitialLines.Count -gt 0) { ($InitialLines -join "`n") + "`n" } else { "" }
    Write-PZAIAtomicUtf8 -Path $path -Text $text
    Publish-PZAIQueueManifest -LuaDir $LuaDir -Generation $Generation -Filename $filename `
        -PublishedLines $InitialLines.Count -LegacyBaseCursor $LegacyBaseCursor
    return Get-PZAIQueueManifest -LuaDir $LuaDir
}

function Initialize-PZAIResponseQueue {
    param([Parameter(Mandatory)][string]$LuaDir)

    if (-not (Test-Path -LiteralPath $LuaDir -PathType Container)) {
        throw "Server Lua directory does not exist: $LuaDir"
    }
    $manifest = Get-PZAIQueueManifest -LuaDir $LuaDir
    if ($null -eq $manifest) {
        $legacyCursor = Get-PZAILegacyCursor -LuaDir $LuaDir
        $legacy = Get-PZAICompleteLineInfo -Path (Join-Path $LuaDir $script:PZAIQueueLegacyName)
        $start = [Math]::Min($legacy.lineCount, $legacyCursor)
        $unconsumed = if ($start -lt $legacy.lineCount) {
            @($legacy.lines[$start..($legacy.lineCount - 1)] | ForEach-Object {
                ConvertTo-PZAIQueueEnvelope -Payload $_ -AllowInvalidLegacyPayload
            })
        }
        else { @() }
        return New-PZAIQueueGeneration -LuaDir $LuaDir `
            -Generation (Get-PZAINextGeneration -LuaDir $LuaDir) `
            -InitialLines $unconsumed -LegacyBaseCursor $start
    }

    $path = Join-Path $LuaDir $manifest.filename
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Published queue file is missing: $($manifest.filename)"
    }
    $info = Get-PZAICompleteLineInfo -Path $path
    if ($info.lineCount -lt $manifest.publishedLines) {
        throw "Published queue is shorter than its manifest."
    }
    if ($info.fileBytes -ne $info.completeBytes) {
        $stream = [IO.FileStream]::new($path, [IO.FileMode]::Open, [IO.FileAccess]::Write,
            [IO.FileShare]::Read)
        try { $stream.SetLength($info.completeBytes); $stream.Flush($true) }
        finally { $stream.Dispose() }
    }
    if ($info.lineCount -gt $manifest.publishedLines) {
        Publish-PZAIQueueManifest -LuaDir $LuaDir -Generation $manifest.generation `
            -Filename $manifest.filename -PublishedLines $info.lineCount `
            -LegacyBaseCursor $manifest.legacyBaseCursor
        $manifest = Get-PZAIQueueManifest -LuaDir $LuaDir
    }
    return $manifest
}

function Test-PZAIQueueConsumed {
    param([Parameter(Mandatory)][string]$LuaDir, [Parameter(Mandatory)][object]$Manifest)
    $ack = Get-PZAIQueueAck -LuaDir $LuaDir
    return $null -ne $ack -and $ack.generation -eq $Manifest.generation -and
        $ack.filename -eq $Manifest.filename -and $ack.cursor -ge $Manifest.publishedLines
}

function Remove-PZAIAcknowledgedQueueHistory {
    param([Parameter(Mandatory)][string]$LuaDir, [Parameter(Mandatory)][long]$CurrentGeneration)

    $keepFrom = [Math]::Max(1L, $CurrentGeneration - 1)
    foreach ($file in @(Get-ChildItem -LiteralPath $LuaDir -File `
            -Filter 'PZAI-agent-response-queue-g*.jsonl' -ErrorAction SilentlyContinue)) {
        if ($file.Name -match '^PZAI-agent-response-queue-g([0-9]{12})\.jsonl$' -and
                [long]$Matches[1] -lt $keepFrom) {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-PZAIResponseQueueLine {
    param([Parameter(Mandatory)][string]$LuaDir, [Parameter(Mandatory)][string]$Payload)

    $line = ConvertTo-PZAIQueueEnvelope -Payload $Payload
    $recordBytes = $script:PZAIQueueUtf8.GetBytes($line)
    if ($recordBytes.Length -gt $script:PZAIQueueMaxLineBytes) {
        throw "Queue JSONL envelope exceeds its protocol limit."
    }

    $manifest = Initialize-PZAIResponseQueue -LuaDir $LuaDir
    $path = Join-Path $LuaDir $manifest.filename
    $length = (Get-Item -LiteralPath $path).Length
    $rotate = ($manifest.publishedLines -ge $script:PZAIQueueMaxLines -or
        ($length + $recordBytes.Length + 1) -gt $script:PZAIQueueMaxBytes) -and
        (Test-PZAIQueueConsumed -LuaDir $LuaDir -Manifest $manifest)
    if ($rotate) {
        $manifest = New-PZAIQueueGeneration -LuaDir $LuaDir `
            -Generation (Get-PZAINextGeneration -LuaDir $LuaDir) -InitialLines @() `
            -LegacyBaseCursor $manifest.legacyBaseCursor
        $path = Join-Path $LuaDir $manifest.filename
        Remove-PZAIAcknowledgedQueueHistory -LuaDir $LuaDir `
            -CurrentGeneration $manifest.generation
    }

    $stream = $null
    try {
        $stream = [IO.FileStream]::new($path, [IO.FileMode]::Open,
            [IO.FileAccess]::Write, [IO.FileShare]::Read)
        [void]$stream.Seek(0, [IO.SeekOrigin]::End)
        $stream.Write($recordBytes, 0, $recordBytes.Length)
        $stream.WriteByte(10)
        $stream.Flush($true)
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }

    Publish-PZAIQueueManifest -LuaDir $LuaDir -Generation $manifest.generation `
        -Filename $manifest.filename -PublishedLines ($manifest.publishedLines + 1) `
        -LegacyBaseCursor $manifest.legacyBaseCursor
    return Get-PZAIQueueManifest -LuaDir $LuaDir
}
