param(
    [Parameter(Mandatory = $true)]
    [string]$CacheDir,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Message,

    [ValidateNotNullOrEmpty()]
    [string]$Title = "Server Notice",

    [string]$TargetUsername,

    [ValidateSet("info", "success", "warning", "danger")]
    [string]$Style = "info",

    [ValidateRange(3, 300)]
    [int]$DurationSeconds = 10,

    [ValidateSet("small", "medium", "large")]
    [string]$TitleSize = "medium",

    [ValidateSet("small", "medium", "large")]
    [string]$BodySize = "small",

    [string]$AccentColor,

    [string]$TextColor,

    [ValidateRange(0, 128)]
    [int]$ExpectedClients = 0,

    [ValidateRange(0, 60)]
    [int]$ReceiptTimeoutSeconds = 0
)

$ErrorActionPreference = "Stop"
$utf8 = [Text.UTF8Encoding]::new($false)

function Assert-Utf8Bound {
    param([string]$Name, [string]$Value, [int]$MaximumBytes, [switch]$AllowNewlines)

    if ([string]::IsNullOrEmpty($Value)) { throw "$Name must not be empty." }
    if (-not $AllowNewlines -and $Value -match '[\r\n]') {
        throw "$Name must not contain a newline."
    }
    if ($Value -match '[\x00-\x08\x0B\x0C\x0E-\x1F]') {
        throw "$Name contains a control character."
    }
    $bytes = $utf8.GetByteCount($Value)
    if ($bytes -gt $MaximumBytes) {
        throw "$Name is $bytes UTF-8 bytes; maximum is $MaximumBytes."
    }
}

function Normalize-Color {
    param([string]$Name, [string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return "-" }
    if ($Value -notmatch '^#[0-9A-Fa-f]{6}$') {
        throw "$Name must be #RRGGBB."
    }
    return $Value.ToUpperInvariant()
}

function Wait-NoticeQueueUnlocked {
    param([string]$LuaDirectory, [int]$TimeoutSeconds = 12)

    $lockPath = Join-Path $LuaDirectory "PZWebNotices-queue.lock"
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (Test-Path -LiteralPath $lockPath -PathType Leaf) {
        $values = @{}
        try {
            foreach ($lockLine in Get-Content -LiteralPath $lockPath -Encoding UTF8 -ErrorAction Stop) {
                if ($lockLine -match '^(?<name>[A-Za-z][A-Za-z0-9]*)=(?<value>.*)$') { $values[$Matches.name] = $Matches.value }
            }
        }
        catch { return }
        if ([string]$values.locked -ne "1") { return }
        $expiresMs = 0L
        [void][long]::TryParse([string]$values.expiresMs, [ref]$expiresMs)
        if ($expiresMs -gt 0 -and [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() -ge $expiresMs) { return }
        if ((Get-Date) -ge $deadline) { throw "PZWebNotices queue compaction lock timed out." }
        Start-Sleep -Milliseconds 100
    }
}

$resolvedCacheDir = [IO.Path]::GetFullPath($CacheDir).TrimEnd('\')
if (-not (Test-Path -LiteralPath $resolvedCacheDir -PathType Container)) {
    throw "Cache directory was not found: $resolvedCacheDir"
}
$luaDir = Join-Path $resolvedCacheDir "Lua"
New-Item -ItemType Directory -Path $luaDir -Force | Out-Null
$resolvedLuaDir = [IO.Path]::GetFullPath($luaDir).TrimEnd('\') + '\'
$queuePath = [IO.Path]::GetFullPath((Join-Path $luaDir "PZWebNotices-queue.txt"))
if (-not $queuePath.StartsWith($resolvedLuaDir, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Notice queue escaped the selected cache directory."
}
$heartbeatPath = Join-Path $luaDir "PZWebNotices-heartbeat.ini"
if (Test-Path -LiteralPath $heartbeatPath -PathType Leaf) {
    $versionLine = Get-Content -LiteralPath $heartbeatPath -Encoding UTF8 |
        Where-Object { $_ -match '^version=(.+)$' } |
        Select-Object -First 1
    if ($versionLine -match '^version=(.+)$') {
        $heartbeatVersion = [version]$Matches[1]
        if ($heartbeatVersion -lt [version]"0.2.3") {
            throw "PZWebNotices $heartbeatVersion does not support the UTF-8-safe v3 queue. Update the selected server to 0.2.3 or later."
        }
    }
}

Assert-Utf8Bound -Name "Title" -Value $Title -MaximumBytes 240
Assert-Utf8Bound -Name "Message" -Value $Message -MaximumBytes 4096 -AllowNewlines
$targetType = "all"
$target = ""
if (-not [string]::IsNullOrWhiteSpace($TargetUsername)) {
    Assert-Utf8Bound -Name "TargetUsername" -Value $TargetUsername -MaximumBytes 64
    $targetType = "player"
    $target = $TargetUsername
}

$id = "notice-" + [guid]::NewGuid().ToString("N")
function ConvertTo-QueueText {
    param([string]$Value)

    return $Value.Replace('%', '%25').Replace("`t", '%09').Replace("`r", '%0D').Replace("`n", '%0A')
}
$fields = @(
    "v3", $id, $targetType, (ConvertTo-QueueText $target), $Style,
    $DurationSeconds.ToString([Globalization.CultureInfo]::InvariantCulture),
    $TitleSize, $BodySize,
    (Normalize-Color -Name "AccentColor" -Value $AccentColor),
    (Normalize-Color -Name "TextColor" -Value $TextColor),
    (ConvertTo-QueueText $Title), (ConvertTo-QueueText $Message),
    $ExpectedClients.ToString([Globalization.CultureInfo]::InvariantCulture)
)
$line = ($fields -join "`t") + "`n"

Wait-NoticeQueueUnlocked -LuaDirectory $luaDir
$stream = $null
try {
    $stream = [IO.FileStream]::new(
        $queuePath,
        [IO.FileMode]::OpenOrCreate,
        [IO.FileAccess]::Write,
        [IO.FileShare]::Read
    )
    [void]$stream.Seek(0, [IO.SeekOrigin]::End)
    $bytes = $utf8.GetBytes($line)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
}
finally {
    if ($null -ne $stream) { $stream.Dispose() }
}

$result = [ordered]@{
    schema = "pzwebnotices.queue-result/1"
    id = $id
    targetType = $targetType
    targetUsername = $target
    queuePath = $queuePath
    status = "queued"
}

if ($ReceiptTimeoutSeconds -gt 0) {
    $receiptPaths = @(
        (Join-Path $luaDir "PZWebNotices-receipts.log"),
        (Join-Path $luaDir "PZWebNotices-receipts.log.1")
    )
    $deadline = (Get-Date).AddSeconds($ReceiptTimeoutSeconds)
    do {
        $match = $null
        foreach ($receiptPath in $receiptPaths) {
            if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) { continue }
            $candidate = Get-Content -LiteralPath $receiptPath -Encoding UTF8 -Tail 256 |
                Where-Object { $_.StartsWith($id + "`t", [StringComparison]::Ordinal) } |
                Select-Object -Last 1
            if ($null -ne $candidate) { $match = $candidate }
        }
        if ($null -ne $match) {
            $parts = $match -split "`t", 5
            $result.status = $parts[1]
            $result.receiptDetail = if ($parts.Count -gt 3) { $parts[3] } else { "" }
            break
        }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
}

[Console]::OutputEncoding = $utf8
$result | ConvertTo-Json -Depth 4
