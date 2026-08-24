param(
    [string]$ServerName,
    [string]$CacheDir,
    [string]$PanelRoot,
    [switch]$Compact
)

$ErrorActionPreference = "Stop"

function Get-CommandLineArgument {
    param(
        [string]$CommandLine,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $null }
    $pattern = '(?i)(?:^|\s)-' + [regex]::Escape($Name) + '(?:=|\s+)(?:"(?<quoted>[^"]*)"|(?<bare>\S+))'
    $match = [regex]::Match($CommandLine, $pattern)
    if (-not $match.Success) { return $null }
    if ($match.Groups['quoted'].Success) { return $match.Groups['quoted'].Value }
    return $match.Groups['bare'].Value
}

function Get-JvmSizeArgument {
    param([string]$CommandLine, [string]$Name)

    $match = [regex]::Match([string]$CommandLine, '(?i)(?:^|\s)-' + [regex]::Escape($Name) + '(?<value>\d+[kmg]?)\b')
    if ($match.Success) { return $match.Groups['value'].Value }
    return $null
}

function Get-JavaAgents {
    param([string]$CommandLine, [string]$RuntimeRoot)

    $items = @()
    foreach ($match in [regex]::Matches([string]$CommandLine, '(?i)(?:^|\s)-javaagent:(?:"(?<quoted>[^"]+)"|(?<bare>\S+))')) {
        $spec = if ($match.Groups['quoted'].Success) { $match.Groups['quoted'].Value } else { $match.Groups['bare'].Value }
        $separator = $spec.IndexOf('=')
        $jar = if ($separator -ge 0) { $spec.Substring(0, $separator) } else { $spec }
        $options = if ($separator -ge 0) { $spec.Substring($separator + 1) } else { '' }
        $resolved = $jar
        if (-not [IO.Path]::IsPathRooted($resolved) -and -not [string]::IsNullOrWhiteSpace($RuntimeRoot)) {
            $resolved = Join-Path $RuntimeRoot $resolved
        }
        try { $resolved = [IO.Path]::GetFullPath($resolved) } catch { }
        $items += [ordered]@{
            name = [IO.Path]::GetFileName($jar)
            argumentPath = $jar
            resolvedPath = $resolved
            options = $options
            filePresent = Test-Path -LiteralPath $resolved -PathType Leaf
        }
    }
    return @($items)
}

function Find-PanelRoot {
    if (-not [string]::IsNullOrWhiteSpace($PanelRoot)) {
        try { return [IO.Path]::GetFullPath($PanelRoot) } catch { return $PanelRoot }
    }
    foreach ($candidate in Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue) {
        $match = [regex]::Match([string]$candidate.CommandLine, '(?i)-File\s+"?(?<path>[^"\r\n]*PZ-ControlPanel\.ps1)"?')
        if ($match.Success) { return Split-Path -Parent $match.Groups['path'].Value.Trim() }
    }
    if ($env:PZ_PANEL_ROOT) { return $env:PZ_PANEL_ROOT }
    return $null
}

function Get-ManagedProfile {
    param([string]$Root, [string]$Name, [string]$DataRoot)

    if ([string]::IsNullOrWhiteSpace($Root)) { return $null }
    $managedRoot = Join-Path $Root 'managed'
    if (-not (Test-Path -LiteralPath $managedRoot -PathType Container)) { return $null }
    foreach ($file in Get-ChildItem -LiteralPath $managedRoot -Recurse -File -Filter 'profile.json' -ErrorAction SilentlyContinue) {
        try {
            $profile = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $nameMatches = [string]$profile.serverName -ieq $Name
            $rootMatches = $false
            if ($profile.dataRoot -and $DataRoot) {
                $rootMatches = [IO.Path]::GetFullPath([string]$profile.dataRoot) -ieq [IO.Path]::GetFullPath($DataRoot)
            }
            if ($nameMatches -and ($rootMatches -or -not $DataRoot)) {
                return [ordered]@{
                    path = $file.FullName
                    id = [string]$profile.id
                    consoleLog = [string]$profile.consoleLog
                    configuredArguments = [string]$profile.arguments
                }
            }
        } catch { }
    }
    return $null
}

$normalizedCacheDir = $null
if ($CacheDir) { $normalizedCacheDir = [IO.Path]::GetFullPath($CacheDir) }
$resolvedPanelRoot = Find-PanelRoot
$logicalProcessors = [Environment]::ProcessorCount
$servers = @()

foreach ($process in Get-CimInstance Win32_Process -Filter "Name='java.exe' OR Name='javaw.exe'" -ErrorAction Stop) {
    $commandLine = [string]$process.CommandLine
    if ($commandLine -notmatch '(?i)(?:^|\s)zombie\.network\.GameServer(?:\s|$)') { continue }

    $name = Get-CommandLineArgument -CommandLine $commandLine -Name 'servername'
    if ([string]::IsNullOrWhiteSpace($name)) { $name = 'servertest' }
    $dataRoot = Get-CommandLineArgument -CommandLine $commandLine -Name 'cachedir'
    if ([string]::IsNullOrWhiteSpace($dataRoot)) { $dataRoot = Join-Path $HOME 'Zomboid' }
    try { $dataRoot = [IO.Path]::GetFullPath($dataRoot) } catch { }

    if ($ServerName -and $name -ine $ServerName) { continue }
    if ($normalizedCacheDir -and $dataRoot -ine $normalizedCacheDir) { continue }

    $runtimeRoot = $null
    if ($process.ExecutablePath) {
        try {
            $binRoot = Split-Path -Parent ([IO.Path]::GetFullPath([string]$process.ExecutablePath))
            $jreRoot = Split-Path -Parent $binRoot
            $runtimeRoot = Split-Path -Parent $jreRoot
        } catch { }
    }
    $profile = Get-ManagedProfile -Root $resolvedPanelRoot -Name $name -DataRoot $dataRoot
    $consoleLog = if ($profile -and $profile.consoleLog) { [string]$profile.consoleLog } else { Join-Path $dataRoot 'server-console.txt' }
    try { $consoleLog = [IO.Path]::GetFullPath($consoleLog) } catch { }

    $servers += [ordered]@{
        serverName = $name
        pid = [int]$process.ProcessId
        processCreatedAt = if ($process.CreationDate) { ([datetime]$process.CreationDate).ToString('o') } else { $null }
        executable = [string]$process.ExecutablePath
        runtimeRoot = $runtimeRoot
        cacheDir = $dataRoot
        consoleLog = $consoleLog
        consoleLogPresent = Test-Path -LiteralPath $consoleLog -PathType Leaf
        xms = Get-JvmSizeArgument -CommandLine $commandLine -Name 'Xms'
        xmx = Get-JvmSizeArgument -CommandLine $commandLine -Name 'Xmx'
        logicalProcessors = $logicalProcessors
        javaAgents = @(Get-JavaAgents -CommandLine $commandLine -RuntimeRoot $runtimeRoot)
        managedProfile = $profile
        commandLine = $commandLine
    }
}

$result = [ordered]@{
    schema = 'pz-server-inventory/1'
    generatedAt = (Get-Date).ToString('o')
    panelRoot = $resolvedPanelRoot
    count = $servers.Count
    servers = @($servers | Sort-Object serverName)
}

[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Write-Output ($result | ConvertTo-Json -Depth 12 -Compress:$Compact)
