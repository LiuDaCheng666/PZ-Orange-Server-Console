$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$profilesPath = Join-Path $root "servers.json"
$aiConfigPath = Join-Path $root "ai-config.json"
$utf8 = [Text.UTF8Encoding]::new($false)

$hasExistingProfiles = $false
if (Test-Path -LiteralPath $profilesPath -PathType Leaf) {
    try {
        $existing = Get-Content -LiteralPath $profilesPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $hasExistingProfiles = @($existing.servers).Count -gt 0
    }
    catch { }
}

function Get-CommandLineArgument {
    param([string]$CommandLine, [string]$Name)
    $escaped = [regex]::Escape($Name)
    $match = [regex]::Match($CommandLine, "(?i)(?:^|\s)-$escaped(?:=|\s+)(?:`"([^`"]+)`"|(\S+))")
    if (-not $match.Success) { return $null }
    if ($match.Groups[1].Success) { return $match.Groups[1].Value }
    return $match.Groups[2].Value
}

function Read-Ini {
    param([string]$Path)
    $values = @{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $values }
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue) {
        if ($line -match '^([^#;=]+)=(.*)$') { $values[$matches[1].Trim()] = $matches[2].Trim() }
    }
    return $values
}

function Get-LanAddress {
    $address = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" } |
        Sort-Object InterfaceMetric |
        Select-Object -First 1 -ExpandProperty IPAddress
    if ($address) { return [string]$address }
    return "127.0.0.1"
}

function New-ProfileId {
    param([string]$ServerName, [string[]]$Used)
    $base = (($ServerName.ToLowerInvariant() -replace '[^a-z0-9_-]', '-') -replace '-+', '-').Trim('-_')
    if (-not $base) { $base = "pz-server" }
    if ($base.Length -gt 27) { $base = $base.Substring(0, 27).TrimEnd('-','_') }
    $id, $suffix = $base, 2
    while ($id -in $Used) {
        $tail = "-$suffix"
        $id = $base.Substring(0, [math]::Min($base.Length, 32 - $tail.Length)).TrimEnd('-','_') + $tail
        $suffix++
    }
    return $id
}

if (-not $hasExistingProfiles) {
$lanAddress = Get-LanAddress
$profiles = @()
$usedIds = @()
$processes = @(Get-CimInstance Win32_Process -Filter "Name='java.exe' OR Name='javaw.exe'" -ErrorAction SilentlyContinue |
    Where-Object { [string]$_.CommandLine -like '*zombie.network.GameServer*' })

foreach ($process in $processes) {
    $javaPath = [string]$process.ExecutablePath
    if (-not $javaPath -or -not [IO.Path]::IsPathRooted($javaPath)) { continue }
    $runtimeRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $javaPath))
    $dataRoot = Get-CommandLineArgument -CommandLine ([string]$process.CommandLine) -Name "cachedir"
    if (-not $dataRoot) { $dataRoot = Join-Path $env:USERPROFILE "Zomboid" }
    $serverName = Get-CommandLineArgument -CommandLine ([string]$process.CommandLine) -Name "servername"
    if (-not $serverName) { $serverName = "servertest" }
    try {
        $javaPath = [IO.Path]::GetFullPath($javaPath)
        $runtimeRoot = [IO.Path]::GetFullPath($runtimeRoot)
        $dataRoot = [IO.Path]::GetFullPath($dataRoot)
    }
    catch { continue }

    $settings = Read-Ini -Path (Join-Path $dataRoot "Server\$serverName.ini")
    $port = 16261
    if ($settings.DefaultPort) { [void][int]::TryParse([string]$settings.DefaultPort, [ref]$port) }
    $maxPlayers = 32
    if ($settings.MaxPlayers) { [void][int]::TryParse([string]$settings.MaxPlayers, [ref]$maxPlayers) }
    $id = New-ProfileId -ServerName $serverName -Used $usedIds
    $usedIds += $id
    $profiles += [pscustomobject][ordered]@{
        id = $id
        name = "$serverName（自动发现）"
        kind = "custom"
        serverName = $serverName
        runtimeRoot = $runtimeRoot
        dataRoot = $dataRoot
        javaPath = $javaPath
        statePath = $null
        consoleLog = Join-Path $dataRoot "server-console.txt"
        queueDir = $null
        commandChannel = "readonly"
        startScript = $null
        stopScript = $null
        sourceStartScript = $null
        ports = @($port, ($port + 1))
        lanAddress = "$lanAddress`:$port"
        maxPlayers = [math]::Max(1, [math]::Min(1000, $maxPlayers))
        passwordRequired = -not [string]::IsNullOrEmpty([string]$settings.Password)
        showConsole = $false
    }
}

if ($profiles.Count -eq 0) {
    $placeholderRoot = Join-Path $root "请在服务器配置页修改此路径"
    $profiles = @([pscustomobject][ordered]@{
        id = "setup-required"
        name = "待配置服务器"
        kind = "custom"
        serverName = "servertest"
        runtimeRoot = $placeholderRoot
        dataRoot = Join-Path $placeholderRoot "data"
        javaPath = Join-Path $placeholderRoot "jre64\bin\java.exe"
        statePath = $null
        consoleLog = Join-Path $placeholderRoot "data\server-console.txt"
        queueDir = $null
        commandChannel = "readonly"
        startScript = $null
        stopScript = $null
        sourceStartScript = $null
        ports = @(16261, 16262)
        lanAddress = "$lanAddress`:16261"
        maxPlayers = 32
        passwordRequired = $false
        showConsole = $false
    })
}

$configuration = [pscustomobject][ordered]@{
    defaultServer = [string]$profiles[0].id
    servers = $profiles
}
[IO.File]::WriteAllText($profilesPath, ($configuration | ConvertTo-Json -Depth 8), $utf8)
}

if (-not (Test-Path -LiteralPath $aiConfigPath -PathType Leaf)) {
    $profileConfiguration = Get-Content -LiteralPath $profilesPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $firstProfile = @($profileConfiguration.servers)[0]
    $selectedServers = if ($firstProfile -and [string]$firstProfile.id -ne "setup-required") {
        @([string]$firstProfile.id)
    }
    else { @() }
    $aiConfiguration = [pscustomobject][ordered]@{
        version = 1
        enabled = $false
        provider = "openai-chat"
        apiUrl = "https://api.deepseek.com"
        authMode = "bearer"
        model = ""
        credentialStorage = "windows-dpapi-current-user"
        reasoningEffort = "low"
        disableResponseStorage = $true
        serverIds = $selectedServers
        temperature = 0.3
        maxTokens = 1600
        maxReplyCharacters = 900
        pollMilliseconds = 1000
        requestTimeoutSeconds = 180
        maximumAttempts = 3
        retryBaseDelaySeconds = 3
        globalRequestCooldownSeconds = 3
        noticeDurationSeconds = 15
        memoryTurns = 8
        memoryMinutes = 30
    }
    [IO.File]::WriteAllText($aiConfigPath, ($aiConfiguration | ConvertTo-Json -Depth 8), $utf8)
}
