param(
    [Parameter(Mandatory = $true)]
    [string]$ProfilePath,

    [Parameter(Mandatory = $true, ParameterSetName = "Raw")]
    [string]$Command,

    [Parameter(Mandatory = $true, ParameterSetName = "Broadcast")]
    [ValidateLength(1, 400)]
    [string]$BroadcastMessage,

    [switch]$AllowStateChangingCommand,

    [ValidateRange(1, 60)]
    [int]$ReceiptTimeoutSeconds = 10
)

$ErrorActionPreference = "Stop"
$utf8 = [Text.UTF8Encoding]::new($false)

if ($PSCmdlet.ParameterSetName -eq "Broadcast") {
    if ([string]::IsNullOrWhiteSpace($BroadcastMessage) -or
            $BroadcastMessage -match '[\r\n"]') {
        throw "Broadcast text must be one non-empty line without double quotes."
    }
    $Command = 'servermsg "' + $BroadcastMessage + '"'
}

if ($Command -match "[\r\n]" -or [string]::IsNullOrWhiteSpace($Command) -or $Command.Length -gt 512) {
    throw "Command must be one non-empty line of at most 512 characters."
}

$safeReadOrMessage = $Command -match '^(?i)(players|help(?:\s+.*)?|servermsg\s+"(?:[^"\\]|\\.)*")$'
if (-not $safeReadOrMessage -and -not $AllowStateChangingCommand) {
    throw "This command may change server state. Repeat with -AllowStateChangingCommand only after explicit user authorization."
}

$resolvedProfile = [IO.Path]::GetFullPath($ProfilePath)
if (-not (Test-Path -LiteralPath $resolvedProfile -PathType Leaf)) {
    throw "Managed server profile was not found: $resolvedProfile"
}
$profile = Get-Content -LiteralPath $resolvedProfile -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($name in @("queueDir", "receiptDir", "statePath", "serverName")) {
    if ([string]::IsNullOrWhiteSpace([string]$profile.$name)) {
        throw "Managed server profile is missing $name."
    }
}

$state = Get-Content -LiteralPath ([string]$profile.statePath) -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$state.status -ne "running" -or -not $state.javaPid) {
    throw "The selected managed server is not running."
}
if ([string]$state.serverName -ne [string]$profile.serverName) {
    throw "Managed profile and runtime state identify different servers."
}

New-Item -ItemType Directory -Path ([string]$profile.queueDir) -Force | Out-Null
New-Item -ItemType Directory -Path ([string]$profile.receiptDir) -Force | Out-Null
$id = [guid]::NewGuid().ToString("N")
$request = [ordered]@{
    id = $id
    command = $Command
    requireReceipt = $true
    createdAt = (Get-Date).ToString("o")
}
$requestPath = Join-Path ([string]$profile.queueDir) "$id.json"
$tempPath = "$requestPath.$([guid]::NewGuid().ToString('N')).tmp"
try {
    [IO.File]::WriteAllText($tempPath, ($request | ConvertTo-Json -Depth 4), $utf8)
    Move-Item -LiteralPath $tempPath -Destination $requestPath
}
finally { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }

$receiptPath = Join-Path ([string]$profile.receiptDir) "$id.json"
$deadline = (Get-Date).AddSeconds($ReceiptTimeoutSeconds)
do {
    if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
        $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
        [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
        [Console]::WriteLine(($receipt | ConvertTo-Json -Depth 8))
        if ([string]$receipt.status -eq "failed") { exit 2 }
        exit 0
    }
    Start-Sleep -Milliseconds 200
} while ((Get-Date) -lt $deadline)

throw "Command was queued as $id, but no receipt arrived within $ReceiptTimeoutSeconds seconds."
