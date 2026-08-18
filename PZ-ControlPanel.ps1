param(
    [int]$Port = 8790
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$webRoot = Join-Path $root "web"
$pidPath = Join-Path $root "panel-state.json"
$requestStatePath = Join-Path $root "request-state.json"
$stopRequestPath = Join-Path $root "panel-stop.request"
$auditPath = Join-Path $root "audit.log"
$profilesPath = Join-Path $root "servers.json"
$profilesBackupPath = Join-Path $root "servers.json.bak"
$usersPath = Join-Path $root "users.json"
$maintenanceSchedulesPath = Join-Path $root "maintenance-schedules.json"
$aiOperationPoliciesPath = Join-Path $root "ai-operation-policies.json"
$broadcastSchedulesPath = Join-Path $root "broadcast-schedules.json"
$executionHistoryPath = Join-Path $root "execution-history.json"
$managedRoot = Join-Path $root "managed"
$managedHostPath = Join-Path $managedRoot "Run-ManagedPZHost.ps1"
$managedLifecyclePath = Join-Path $managedRoot "Invoke-ManagedPZLifecycle.ps1"
$playerDbReaderPath = Join-Path $root "Read-PZPlayers.js"
$playerDataManagerPath = Join-Path $root "Manage-PZPlayerData.js"
$itemIndexRoot = Join-Path $root "item-index"
$itemIndexBuilderPath = Join-Path $root "Build-PZItemIndex.js"
$mapResetRoot = Join-Path $root "map-reset"
$mapResetToolPath = Join-Path $root "tools\PZSelectiveWorldReset\pz_selective_world_reset.py"
$mapResetRunnerPath = Join-Path $root "tools\PZSelectiveWorldReset\Invoke-PZSelectiveWorldReset.ps1"
$aiBridgeModulePath = Join-Path $root "PZ-AIBridge.ps1"
$aiKnowledgeRoot = Join-Path $root "服务器信息库"
$hostStartupTaskScript = Join-Path $root "Set-PZPanelStartupTask.ps1"
$hostAutoLogonScript = Join-Path $root "Configure-PZPanelAutoLogon.ps1"
$hostAutoLogonLauncherPath = Join-Path $root "配置自动进入桌面.bat"
$hostRestartStatePath = Join-Path $root "host-restart-state.json"
$hostStartupTaskName = "PZ Orange Server Console - Startup"
$utf8 = [Text.UTF8Encoding]::new($false)
$statusCache = $null
$statusCacheAt = [datetime]::MinValue
$pzProcessInfoCache = @()
$pzProcessInfoCacheAt = [datetime]::MinValue
$onlinePlayerCache = @{}
$itemIndexCache = @{}
$systemMetricsCache = $null
$systemMetricsCacheAt = [datetime]::MinValue
$systemStaticCache = $null
$processCpuSamples = @{}
$networkSamples = @{}
$jvmMemoryCache = @{}
$commandRequests = @{}
$maintenanceSchedules = @{}
$maintenanceChecks = @{}
$maintenanceLastTick = [datetime]::MinValue
$aiOperationPolicies = @()
$broadcastSchedules = @()
$broadcastLastDispatchAt = @{}
$broadcastDispatchSpacingSeconds = 30
$executionHistory = @()
$executionHistoryLastTick = [datetime]::MinValue
$sessions = @{}
$loginAttempts = @{}
$sessionCookieName = "PZSESSION"
$sessionLifetime = [timespan]::FromHours(12)
$passwordIterations = 310000

function Find-NodeRuntime {
    $portableNode = Join-Path $root "runtime\node.exe"
    if (Test-Path -LiteralPath $portableNode -PathType Leaf) { return $portableNode }
    $command = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $runtimeRoot = Join-Path $env:LOCALAPPDATA "OpenAI\Codex\runtimes\cua_node"
    if (Test-Path -LiteralPath $runtimeRoot) {
        $candidate = Get-ChildItem -LiteralPath $runtimeRoot -Filter node.exe -File -Recurse -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($candidate) { return $candidate.FullName }
    }
    return $null
}

$nodeRuntimePath = Find-NodeRuntime

function Find-PythonRuntime {
    $candidates = @(
        (Join-Path $root "runtime\python\python.exe"),
        (Join-Path $env:USERPROFILE ".cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe")
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    foreach ($name in @("python.exe", "py.exe")) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }
    return $null
}

$pythonRuntimePath = Find-PythonRuntime

if (-not (Test-Path -LiteralPath $profilesPath)) { throw "缺少服务器配置文件：$profilesPath" }
$profileConfig = Get-Content -LiteralPath $profilesPath -Raw -Encoding UTF8 | ConvertFrom-Json
$serverProfiles = @($profileConfig.servers)
if ($serverProfiles.Count -eq 0) { throw "服务器配置文件中没有服务器。" }
foreach ($profile in $serverProfiles) {
    if ([string]$profile.id -notmatch '^[a-z0-9][a-z0-9_-]{0,31}$') { throw "服务器 ID 格式无效。" }
    if ([string]::IsNullOrWhiteSpace([string]$profile.javaPath)) { throw "服务器 $($profile.id) 缺少 javaPath。" }
    if (-not $profile.PSObject.Properties["showConsole"]) {
        $profile | Add-Member -NotePropertyName "showConsole" -NotePropertyValue $false
    }
    else { $profile.showConsole = [bool]$profile.showConsole }
}

[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8

function Write-JsonResponse {
    param($Context, [int]$StatusCode, $Data)
    $json = $Data | ConvertTo-Json -Depth 8 -Compress
    $bytes = $utf8.GetBytes($json)
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = "application/json; charset=utf-8"
    $Context.Response.Headers["Cache-Control"] = "no-store, no-cache, must-revalidate"
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.Close()
}

function Write-TextResponse {
    param($Context, [int]$StatusCode, [string]$Text, [string]$ContentType)
    $bytes = $utf8.GetBytes($Text)
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = "$ContentType; charset=utf-8"
    $Context.Response.Headers["Cache-Control"] = "no-store, no-cache, must-revalidate"
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.Close()
}

function ConvertTo-CsvCell {
    param([AllowNull()][object]$Value)
    $text = if ($null -eq $Value) { "" } else { [string]$Value }
    return '"' + $text.Replace('"', '""') + '"'
}

function Write-CsvDownload {
    param($Context, [string]$FileName, [string[]]$Lines)
    $content = ($Lines -join "`r`n") + "`r`n"
    $preamble = [Text.UTF8Encoding]::new($true).GetPreamble()
    $body = $utf8.GetBytes($content)
    $bytes = [byte[]]::new($preamble.Length + $body.Length)
    [Array]::Copy($preamble, 0, $bytes, 0, $preamble.Length)
    [Array]::Copy($body, 0, $bytes, $preamble.Length, $body.Length)
    $safeFileName = $FileName.Replace('"', '').Replace("`r", '').Replace("`n", '')
    $Context.Response.StatusCode = 200
    $Context.Response.ContentType = "text/csv; charset=utf-8"
    $Context.Response.AddHeader("Content-Disposition", "attachment; filename=`"$safeFileName`"")
    $Context.Response.AddHeader("Cache-Control", "no-store")
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.Close()
}

function Get-RequestBody {
    param($Request)
    $reader = [IO.StreamReader]::new($Request.InputStream, $utf8, $true)
    try { return $reader.ReadToEnd() | ConvertFrom-Json }
    finally { $reader.Dispose() }
}

function Get-Utf8QueryValue {
    param($Request, [string]$Name)
    $rawUrl = [string]$Request.RawUrl
    $separator = $rawUrl.IndexOf('?')
    if ($separator -lt 0) { return $null }
    foreach ($part in $rawUrl.Substring($separator + 1).Split('&')) {
        $pair = $part.Split('=', 2)
        $key = [Uri]::UnescapeDataString($pair[0].Replace('+', ' '))
        if ($key -ceq $Name) {
            if ($pair.Count -lt 2) { return "" }
            return [Uri]::UnescapeDataString($pair[1].Replace('+', ' '))
        }
    }
    return $null
}

function ConvertTo-Base64Url {
    param([byte[]]$Bytes)
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-RandomToken {
    param([int]$ByteCount = 32)
    $bytes = [byte[]]::new($ByteCount)
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return ConvertTo-Base64Url $bytes
}

function Get-PasswordHash {
    param([string]$Password, [byte[]]$Salt, [int]$Iterations)
    $derive = [Security.Cryptography.Rfc2898DeriveBytes]::new(
        $Password,
        $Salt,
        $Iterations,
        [Security.Cryptography.HashAlgorithmName]::SHA256
    )
    try { return $derive.GetBytes(32) } finally { $derive.Dispose() }
}

function Test-FixedTimeEqual {
    param([byte[]]$Left, [byte[]]$Right)
    if ($Left.Length -ne $Right.Length) { return $false }
    $difference = 0
    for ($index = 0; $index -lt $Left.Length; $index++) {
        $difference = $difference -bor ($Left[$index] -bxor $Right[$index])
    }
    return $difference -eq 0
}

function Read-Users {
    if (-not (Test-Path -LiteralPath $usersPath)) { return @() }
    try {
        $document = Get-Content -LiteralPath $usersPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return @($document.users)
    }
    catch { throw "用户文件损坏，无法读取：$usersPath" }
}

function Save-Users {
    param([object[]]$Users)
    $tempPath = "$usersPath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($tempPath, ([ordered]@{ version = 1; users = @($Users) } | ConvertTo-Json -Depth 6), $utf8)
        Move-Item -LiteralPath $tempPath -Destination $usersPath -Force
    }
    finally { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
}

function Assert-LoginName {
    param([string]$Value)
    $name = $Value.Trim()
    if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{2,31}$') {
        throw "登录名必须为 3 至 32 位，只能使用字母、数字、点、下划线和连字符。"
    }
    return $name
}

function Assert-PanelPassword {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -lt 10 -or $Value.Length -gt 128) {
        throw "密码必须为 10 至 128 个字符。"
    }
    return $Value
}

function New-PanelUser {
    param([string]$Username, [string]$DisplayName, [string]$Password, [bool]$Enabled = $true, [bool]$CanManagePlayerData = $false)
    $salt = [byte[]]::new(32)
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($salt) } finally { $rng.Dispose() }
    $now = (Get-Date).ToString("o")
    return [pscustomobject][ordered]@{
        id = [guid]::NewGuid().ToString("N")
        username = Assert-LoginName $Username
        displayName = Assert-SimpleText -Value $DisplayName -Name "显示名称" -MaxLength 64
        passwordSalt = [Convert]::ToBase64String($salt)
        passwordHash = [Convert]::ToBase64String((Get-PasswordHash -Password (Assert-PanelPassword $Password) -Salt $salt -Iterations $passwordIterations))
        iterations = $passwordIterations
        enabled = $Enabled
        canManagePlayerData = $CanManagePlayerData
        createdAt = $now
        updatedAt = $now
        sessionVersion = 1
    }
}

function Get-RequestCookieValue {
    param($Request, [string]$Name)
    $cookie = $Request.Cookies[$Name]
    if ($cookie) { return [string]$cookie.Value }
    return $null
}

function Set-SessionCookie {
    param($Response, [string]$Token)
    $Response.AppendHeader("Set-Cookie", "$sessionCookieName=$Token; Path=/; HttpOnly; SameSite=Strict; Max-Age=$([int]$sessionLifetime.TotalSeconds)")
}

function Clear-SessionCookie {
    param($Response)
    $Response.AppendHeader("Set-Cookie", "$sessionCookieName=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0")
}

function Get-AuthenticatedSession {
    param($Request)
    $token = Get-RequestCookieValue -Request $Request -Name $sessionCookieName
    if ([string]::IsNullOrWhiteSpace($token) -or -not $sessions.ContainsKey($token)) { return $null }
    $session = $sessions[$token]
    if ((Get-Date) -ge $session.expiresAt) {
        $sessions.Remove($token)
        return $null
    }
    $user = Read-Users | Where-Object { [string]$_.id -ceq [string]$session.userId } | Select-Object -First 1
    if (-not $user -or -not [bool]$user.enabled -or [int]$user.sessionVersion -ne [int]$session.sessionVersion) {
        $sessions.Remove($token)
        return $null
    }
    $session.user = $user
    return $session
}

function New-AuthenticatedSession {
    param($User)
    $token = New-RandomToken
    $session = [pscustomobject]@{
        userId = [string]$User.id
        sessionVersion = [int]$User.sessionVersion
        csrf = New-RandomToken -ByteCount 24
        createdAt = Get-Date
        expiresAt = (Get-Date).Add($sessionLifetime)
        user = $User
    }
    $sessions[$token] = $session
    return [pscustomobject]@{ token = $token; session = $session }
}

function Test-LoginAllowed {
    param([string]$Remote)
    if (-not $loginAttempts.ContainsKey($Remote)) { return $true }
    $attempt = $loginAttempts[$Remote]
    if ($attempt.blockedUntil -and (Get-Date) -lt $attempt.blockedUntil) { return $false }
    if (((Get-Date) - $attempt.windowStart).TotalMinutes -ge 10) {
        $loginAttempts.Remove($Remote)
        return $true
    }
    return $true
}

function Add-LoginFailure {
    param([string]$Remote)
    $now = Get-Date
    if (-not $loginAttempts.ContainsKey($Remote) -or ($now - $loginAttempts[$Remote].windowStart).TotalMinutes -ge 10) {
        $loginAttempts[$Remote] = [pscustomobject]@{ count = 0; windowStart = $now; blockedUntil = $null }
    }
    $attempt = $loginAttempts[$Remote]
    $attempt.count++
    if ($attempt.count -ge 5) { $attempt.blockedUntil = $now.AddMinutes(15) }
}

function Test-Csrf {
    param($Request, $Session)
    return $Session -and -not [string]::IsNullOrWhiteSpace([string]$Request.Headers["X-PZ-CSRF"]) -and
        [string]$Request.Headers["X-PZ-CSRF"] -ceq [string]$Session.csrf
}

function Get-PublicUser {
    param($User)
    return [ordered]@{
        id = [string]$User.id
        username = [string]$User.username
        displayName = [string]$User.displayName
        enabled = [bool]$User.enabled
        canManagePlayerData = [bool]([string]$User.username -ieq "admin" -or ($User.PSObject.Properties["canManagePlayerData"] -and [bool]$User.canManagePlayerData))
        createdAt = [string]$User.createdAt
        updatedAt = [string]$User.updatedAt
    }
}

function Test-LocalRequest {
    param($Request)
    $address = $Request.RemoteEndPoint.Address
    return [Net.IPAddress]::IsLoopback($address)
}

function Assert-HostControlAdministrator {
    param($Session)
    if (-not $Session -or [string]$Session.user.username -ine "admin") {
        throw "只有 Web 保留管理员账号 admin 可以执行此管理操作。"
    }
}

function Test-PlayerDataPermission {
    param($Session)
    if (-not $Session -or -not $Session.user) { return $false }
    if ([string]$Session.user.username -ieq "admin") { return $true }
    return [bool]($Session.user.PSObject.Properties["canManagePlayerData"] -and [bool]$Session.user.canManagePlayerData)
}

function Assert-PlayerDataPermission {
    param($Session)
    if (-not (Test-PlayerDataPermission -Session $Session)) {
        throw "当前 Web 账号没有玩家档案管理权限。请由 admin 在本机的 Web 用户页面授权。"
    }
}

function Get-HostControlStatus {
    param($Session)
    $task = Get-ScheduledTask -TaskName $hostStartupTaskName -ErrorAction SilentlyContinue
    $taskInfo = if ($task) { Get-ScheduledTaskInfo -TaskName $hostStartupTaskName -ErrorAction SilentlyContinue } else { $null }
    $lastTaskResult = $null
    if ($taskInfo) {
        $rawTaskResult = [uint64]$taskInfo.LastTaskResult
        if ($rawTaskResult -ne [uint32]::MaxValue) { $lastTaskResult = [int64]$rawTaskResult }
    }
    $winlogon = Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -ErrorAction SilentlyContinue
    $states = if ($statusCache -and $statusCache.servers) {
        @($statusCache.servers)
    }
    else {
        @($serverProfiles | ForEach-Object { Get-ServerState -Profile $_ })
    }
    $runningServers = @($states | Where-Object { [bool]$_.alive } | ForEach-Object {
        [ordered]@{ id = [string]$_.id; name = [string]$_.name; javaPid = $_.javaPid }
    })
    $restartState = $null
    if (Test-Path -LiteralPath $hostRestartStatePath -PathType Leaf) {
        try {
            $candidate = Get-Content -LiteralPath $hostRestartStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($candidate.executeAt -and (Get-Date) -lt ([datetime]$candidate.executeAt).AddMinutes(2)) { $restartState = $candidate }
            else { Remove-Item -LiteralPath $hostRestartStatePath -Force -ErrorAction SilentlyContinue }
        }
        catch { Remove-Item -LiteralPath $hostRestartStatePath -Force -ErrorAction SilentlyContinue }
    }
    return [ordered]@{
        authorized = [bool]($Session -and [string]$Session.user.username -ieq "admin")
        startupTask = [ordered]@{
            installed = [bool]$task
            enabled = [bool]($task -and $task.Settings.Enabled)
            state = if ($task) { [string]$task.State } else { "NotInstalled" }
            userId = if ($task) { [string]$task.Principal.UserId } else { $null }
            logonType = if ($task) { [string]$task.Principal.LogonType } else { $null }
            lastRunTime = if ($taskInfo -and $taskInfo.LastRunTime.Year -gt 2000) { $taskInfo.LastRunTime.ToString("o") } else { $null }
            lastTaskResult = $lastTaskResult
        }
        autoLogon = [ordered]@{
            enabled = [string]$winlogon.AutoAdminLogon -eq "1"
            userName = [string]$winlogon.DefaultUserName
            domainName = [string]$winlogon.DefaultDomainName
            configuredByPanel = $false
        }
        allServersStopped = $runningServers.Count -eq 0
        runningServers = $runningServers
        restartPending = [bool]$restartState
        restartExecuteAt = if ($restartState) { [string]$restartState.executeAt } else { $null }
    }
}

function Set-HostStartupTask {
    param([bool]$Enabled)
    if (-not (Test-Path -LiteralPath $hostStartupTaskScript -PathType Leaf)) { throw "缺少开机任务管理脚本。" }
    $mode = if ($Enabled) { "Enable" } else { "Disable" }
    $result = & $hostStartupTaskScript -Mode $mode
    if (-not $result) { throw "开机任务没有返回状态。" }
    return $result
}

function Start-HostRestartCountdown {
    param([string]$RequestedBy, [string]$Remote)
    $running = @($serverProfiles | ForEach-Object { Get-ServerState -Profile $_ } | Where-Object { [bool]$_.alive })
    if ($running.Count -gt 0) {
        throw "仍有游戏服务器正在运行：$((@($running | ForEach-Object { $_.name }) -join '、'))。请先在维护页保存并停止全部服务器。"
    }
    $executeAt = (Get-Date).AddSeconds(30)
    [IO.File]::WriteAllText($hostRestartStatePath, ([ordered]@{
        requestedAt = (Get-Date).ToString("o")
        executeAt = $executeAt.ToString("o")
        requestedBy = $RequestedBy
        remote = $Remote
    } | ConvertTo-Json), $utf8)
    $shutdownPath = Join-Path $env:SystemRoot "System32\shutdown.exe"
    & $shutdownPath /r /t 30 /d p:0:0 /c "PZ Orange Server Console requested a physical host restart." | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Remove-Item -LiteralPath $hostRestartStatePath -Force -ErrorAction SilentlyContinue
        throw "Windows 拒绝安排物理机重启，退出码 $LASTEXITCODE。"
    }
    Add-Audit -Remote $Remote -Action "host-restart" -Detail "requestedBy=$RequestedBy executeAt=$($executeAt.ToString('o')) allServersStopped=true" -Result "queued"
    return $executeAt
}

function Stop-HostRestartCountdown {
    param([string]$RequestedBy, [string]$Remote)
    $shutdownPath = Join-Path $env:SystemRoot "System32\shutdown.exe"
    & $shutdownPath /a | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "当前没有可以取消的 Windows 重启倒计时。" }
    Remove-Item -LiteralPath $hostRestartStatePath -Force -ErrorAction SilentlyContinue
    Add-Audit -Remote $Remote -Action "host-restart-cancel" -Detail "requestedBy=$RequestedBy" -Result "ok"
}

function Add-Audit {
    param([string]$Remote, [string]$Action, [string]$Detail, [string]$Result = "queued")
    $safeDetail = ($Detail -replace "[\r\n]", " ")
    $line = "{0}`t{1}`t{2}`t{3}`t{4}" -f (Get-Date).ToString("o"), $Remote, $Action, $Result, $safeDetail
    [IO.File]::AppendAllText($auditPath, $line + "`r`n", $utf8)
}

function New-DefaultMaintenanceSchedule {
    param([string]$ServerId)
    return [pscustomobject][ordered]@{
        serverId = $ServerId
        enabled = $false
        intervalHours = 3
        autoRestartOnUpdate = $false
        restartStabilizationSeconds = 60
        nextRunAt = $null
        lastRunAt = $null
        lastStatus = "never"
        lastResultCode = $null
        lastMessage = "尚未执行自动 Mod 更新检查。"
        lastRequestId = $null
        updateNotificationPending = $false
        lastNotificationAt = $null
        lastAutoRestartAt = $null
        lastAutoRestartOperationId = $null
    }
}

function Read-MaintenanceSchedules {
    $result = @{}
    if (-not (Test-Path -LiteralPath $maintenanceSchedulesPath -PathType Leaf)) { return $result }
    try {
        $document = Get-Content -LiteralPath $maintenanceSchedulesPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($document.servers) {
            foreach ($property in $document.servers.PSObject.Properties) {
                $saved = $property.Value
                $schedule = New-DefaultMaintenanceSchedule -ServerId ([string]$property.Name)
                foreach ($name in @("enabled", "intervalHours", "autoRestartOnUpdate", "restartStabilizationSeconds", "nextRunAt", "lastRunAt", "lastStatus", "lastResultCode", "lastMessage", "lastRequestId", "updateNotificationPending", "lastNotificationAt", "lastAutoRestartAt", "lastAutoRestartOperationId")) {
                    if ($saved.PSObject.Properties[$name]) { $schedule.$name = $saved.$name }
                }
                $schedule.enabled = [bool]$schedule.enabled
                $schedule.intervalHours = [math]::Max(1, [math]::Min(168, [int]$schedule.intervalHours))
                $schedule.autoRestartOnUpdate = [bool]$schedule.autoRestartOnUpdate
                $schedule.restartStabilizationSeconds = [math]::Max(10, [math]::Min(600, [int]$schedule.restartStabilizationSeconds))
                $schedule.updateNotificationPending = [bool]$schedule.updateNotificationPending
                $result[[string]$property.Name] = $schedule
            }
        }
    }
    catch {
        Add-Audit -Remote "local" -Action "maintenance-schedule-read" -Detail $_.Exception.Message -Result "failed"
    }
    return $result
}

function Save-MaintenanceSchedules {
    $servers = [ordered]@{}
    foreach ($serverId in @($maintenanceSchedules.Keys | Sort-Object)) {
        $servers[$serverId] = $maintenanceSchedules[$serverId]
    }
    $tempPath = "$maintenanceSchedulesPath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($tempPath, ([ordered]@{ version = 1; servers = $servers } | ConvertTo-Json -Depth 6), $utf8)
        Move-Item -LiteralPath $tempPath -Destination $maintenanceSchedulesPath -Force
    }
    finally { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
}

function Get-MaintenanceSchedule {
    param([string]$ServerId)
    if (-not $maintenanceSchedules.ContainsKey($ServerId)) {
        $maintenanceSchedules[$ServerId] = New-DefaultMaintenanceSchedule -ServerId $ServerId
    }
    return $maintenanceSchedules[$ServerId]
}

function Read-AIOperationPolicies {
    if (-not (Test-Path -LiteralPath $aiOperationPoliciesPath -PathType Leaf)) { return @() }
    try {
        $document = Get-Content -LiteralPath $aiOperationPoliciesPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return @($document.policies)
    }
    catch {
        Add-Audit -Remote "local" -Action "ai-policy-read" -Detail $_.Exception.Message -Result "failed"
        return @()
    }
}

function Save-AIOperationPolicies {
    $tempPath = "$aiOperationPoliciesPath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($tempPath, ([ordered]@{ version = 1; policies = @($aiOperationPolicies) } | ConvertTo-Json -Depth 8), $utf8)
        Move-Item -LiteralPath $tempPath -Destination $aiOperationPoliciesPath -Force
    }
    finally { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
}

function Get-AIOperationCatalog {
    return @(
        [ordered]@{ id = "query_status"; label = "查询服务器状态"; risk = "read" },
        [ordered]@{ id = "query_players"; label = "查询在线玩家"; risk = "read" },
        [ordered]@{ id = "query_self"; label = "查询本人状态"; risk = "read" },
        [ordered]@{ id = "send_private_notice"; label = "向本人发送通知"; risk = "low" },
        [ordered]@{ id = "unstuck_self"; label = "本人脱困/传送"; risk = "low" },
        [ordered]@{ id = "give_self_item"; label = "给本人发放限定物品"; risk = "medium" },
        [ordered]@{ id = "add_self_xp"; label = "给本人发放限定经验"; risk = "medium" },
        [ordered]@{ id = "broadcast"; label = "发送全服广播"; risk = "medium" },
        [ordered]@{ id = "give_item"; label = "给其他玩家发放物品"; risk = "high" },
        [ordered]@{ id = "teleport_player"; label = "传送其他玩家"; risk = "high" },
        [ordered]@{ id = "kick_player"; label = "踢出玩家"; risk = "high" },
        [ordered]@{ id = "ban_player"; label = "封禁玩家"; risk = "critical" },
        [ordered]@{ id = "restart_server"; label = "安全重启服务器"; risk = "critical" },
        [ordered]@{ id = "change_config"; label = "修改服务器配置"; risk = "critical" }
    )
}

function Get-PublicAIOperationPolicies {
    return [ordered]@{
        ok = $true
        executorConnected = $false
        executionEnabled = $false
        message = "白名单已经作为未来 AI 执行器的硬权限来源保存；当前执行器尚未接入，因此不会执行游戏操作。"
        operations = @(Get-AIOperationCatalog)
        policies = @($aiOperationPolicies | Sort-Object serverId, username | ForEach-Object {
            [ordered]@{
                id = [string]$_.id
                serverId = [string]$_.serverId
                username = [string]$_.username
                steamId = [string]$_.steamId
                enabled = [bool]$_.enabled
                trustedAll = [bool]$_.trustedAll
                allowedOperations = @($_.allowedOperations)
                createdAt = [string]$_.createdAt
                updatedAt = [string]$_.updatedAt
            }
        })
    }
}

function Read-BroadcastSchedules {
    if (-not (Test-Path -LiteralPath $broadcastSchedulesPath -PathType Leaf)) { return @() }
    try {
        $document = Get-Content -LiteralPath $broadcastSchedulesPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $result = @()
        foreach ($saved in @($document.schedules)) {
            $interval = [math]::Max(5, [math]::Min(10080, [int]$saved.intervalMinutes))
            $result += [pscustomobject][ordered]@{
                id = [string]$saved.id
                serverId = [string]$saved.serverId
                name = [string]$saved.name
                enabled = [bool]$saved.enabled
                channel = [string]$saved.channel
                intervalMinutes = $interval
                title = [string]$saved.title
                message = [string]$saved.message
                duration = [math]::Max(3, [math]::Min(300, [int]$saved.duration))
                style = [string]$saved.style
                nextRunAt = $saved.nextRunAt
                lastRunAt = $saved.lastRunAt
                lastStatus = [string]$saved.lastStatus
                lastMessage = [string]$saved.lastMessage
                createdAt = [string]$saved.createdAt
                updatedAt = [string]$saved.updatedAt
            }
        }
        return $result
    }
    catch {
        Add-Audit -Remote "local" -Action "broadcast-schedule-read" -Detail $_.Exception.Message -Result "failed"
        return @()
    }
}

function Save-BroadcastSchedules {
    $tempPath = "$broadcastSchedulesPath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($tempPath, ([ordered]@{ version = 1; schedules = @($broadcastSchedules) } | ConvertTo-Json -Depth 8), $utf8)
        Move-Item -LiteralPath $tempPath -Destination $broadcastSchedulesPath -Force
    }
    finally { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
}

function Get-BroadcastSchedulesPayload {
    param([string]$ServerId)
    return [ordered]@{
        ok = $true
        serverId = $ServerId
        schedules = @($broadcastSchedules | Where-Object { [string]$_.serverId -ceq $ServerId } | Sort-Object name | ForEach-Object {
            [ordered]@{
                id = [string]$_.id; serverId = [string]$_.serverId; name = [string]$_.name
                enabled = [bool]$_.enabled; channel = [string]$_.channel; intervalMinutes = [int]$_.intervalMinutes
                title = [string]$_.title; message = [string]$_.message; duration = [int]$_.duration; style = [string]$_.style
                nextRunAt = $_.nextRunAt; lastRunAt = $_.lastRunAt; lastStatus = [string]$_.lastStatus
                lastMessage = [string]$_.lastMessage; createdAt = [string]$_.createdAt; updatedAt = [string]$_.updatedAt
            }
        })
    }
}

function Read-ExecutionHistory {
    if (-not (Test-Path -LiteralPath $executionHistoryPath -PathType Leaf)) { return @() }
    try {
        $document = Get-Content -LiteralPath $executionHistoryPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return @($document.records | Select-Object -Last 500)
    }
    catch {
        Add-Audit -Remote "local" -Action "execution-history-read" -Detail $_.Exception.Message -Result "failed"
        return @()
    }
}

function Save-ExecutionHistory {
    if ($executionHistory.Count -gt 500) { $script:executionHistory = @($executionHistory | Select-Object -Last 500) }
    $tempPath = "$executionHistoryPath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($tempPath, ([ordered]@{ version = 1; records = @($executionHistory) } | ConvertTo-Json -Depth 10), $utf8)
        Move-Item -LiteralPath $tempPath -Destination $executionHistoryPath -Force
    }
    finally { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
}

function Add-ExecutionHistoryRecord {
    param(
        [string]$ServerId, [string]$Category, [string]$Action, [string]$Source,
        [string]$Summary, [string]$Status = "queued", [string]$Message = "已提交，等待执行结果。",
        [string[]]$RequestIds = @(), [string[]]$AuxiliaryRequestIds = @(), [string]$NoticeId = "", [string]$OperationId = "", [string]$Detail = "",
        [string]$ClientRequestId = ""
    )
    $now = (Get-Date).ToString("o")
    $record = [pscustomobject][ordered]@{
        id = [guid]::NewGuid().ToString("N")
        serverId = $ServerId
        category = $Category
        action = $Action
        source = $Source
        summary = $Summary
        status = $Status
        resultCode = $null
        message = $Message
        detail = $Detail
        requestIds = @($RequestIds)
        auxiliaryRequestIds = @($AuxiliaryRequestIds)
        noticeId = $NoticeId
        operationId = $OperationId
        clientRequestId = $ClientRequestId
        createdAt = $now
        updatedAt = $now
    }
    $script:executionHistory = @($executionHistory) + $record
    Save-ExecutionHistory
    return $record
}

function Set-ExecutionHistoryResult {
    param($Record, [string]$Status, [string]$ResultCode, [string]$Message, [string]$Detail)
    $Record.status = $Status
    $Record.resultCode = $ResultCode
    $Record.message = $Message
    if ($null -ne $Detail) { $Record.detail = $Detail }
    $Record.updatedAt = (Get-Date).ToString("o")
}

function Get-ExecutionHistoryPayload {
    param(
        [string]$ServerId,
        [string]$Category = "",
        [int]$Page = 1,
        [int]$PageSize = 30,
        [int]$Limit = 0
    )
    if ($Limit -gt 0) { $PageSize = $Limit }
    $PageSize = [math]::Max(1, [math]::Min(30, $PageSize))
    $Page = [math]::Max(1, $Page)
    $records = @($executionHistory | Where-Object {
        ([string]::IsNullOrWhiteSpace($ServerId) -or [string]$_.serverId -ceq $ServerId) -and
        ([string]::IsNullOrWhiteSpace($Category) -or [string]$_.category -ceq $Category)
    })
    [array]::Reverse($records)
    $total = $records.Count
    $totalPages = [math]::Max(1, [int][math]::Ceiling($total / [double]$PageSize))
    $Page = [math]::Min($Page, $totalPages)
    $offset = ($Page - 1) * $PageSize
    $pageRecords = @($records | Select-Object -Skip $offset -First $PageSize)
    return [ordered]@{
        ok = $true
        serverId = $ServerId
        category = $Category
        records = $pageRecords
        page = $Page
        pageSize = $PageSize
        total = $total
        totalPages = $totalPages
    }
}

function Assert-SimpleText {
    param([string]$Value, [string]$Name, [int]$MaxLength = 64)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt $MaxLength -or $Value -match '["\r\n]') {
        throw "$Name 不能为空、不能包含引号或换行，且最长 $MaxLength 个字符。"
    }
    return $Value.Trim()
}

function Normalize-AbsolutePath {
    param([AllowNull()]$Value, [string]$Name, [switch]$Required)
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        if ($Required) { throw "$Name 不能为空。" }
        return $null
    }
    if (-not [IO.Path]::IsPathRooted($text)) { throw "$Name 必须是绝对路径。" }
    try { return [IO.Path]::GetFullPath($text) }
    catch { throw "$Name 不是有效路径。" }
}

function Get-ManagedProfilePaths {
    param([string]$Id)
    $controlRoot = Join-Path $managedRoot $Id
    return [ordered]@{
        controlRoot = $controlRoot
        profilePath = Join-Path $controlRoot "profile.json"
        queueDir = Join-Path $controlRoot "commands"
        receiptDir = Join-Path $controlRoot "receipts"
        statePath = Join-Path $controlRoot "state.json"
        startScript = Join-Path $controlRoot "Start-ManagedPZ.ps1"
        stopScript = Join-Path $controlRoot "Stop-ManagedPZ.ps1"
        restartScript = Join-Path $controlRoot "Restart-ManagedPZ.ps1"
        operationPath = Join-Path $controlRoot "lifecycle-operation.json"
    }
}

function Get-PZAdminDatabasePath {
    param($Profile)
    return Join-Path ([string]$Profile.dataRoot) "db\$([string]$Profile.serverName).db"
}

function Test-PZAdminSetupRequired {
    param($Profile)
    return -not (Test-Path -LiteralPath (Get-PZAdminDatabasePath -Profile $Profile) -PathType Leaf)
}

function Assert-PZInitialAdminPassword {
    param([AllowNull()][string]$Password)
    if ([string]::IsNullOrWhiteSpace($Password) -or $Password.Length -lt 8 -or $Password.Length -gt 128) {
        throw "游戏内置 admin 密码必须为 8 至 128 个字符。"
    }
    if ($Password -match '[\x00-\x1f\x7f"]') {
        throw "游戏内置 admin 密码不能包含引号、换行或控制字符。"
    }
    return $Password
}

function New-ProtectedAdminLaunchSecret {
    param($Profile, [string]$Password)
    if (-not (Test-IsManagedProfile -Profile $Profile)) {
        throw "首次 admin 密码自动初始化仅支持面板自动生成的受控启动脚本。"
    }
    Add-Type -AssemblyName System.Security
    $paths = Get-ManagedProfilePaths -Id ([string]$Profile.id)
    New-Item -ItemType Directory -Path $paths.controlRoot -Force | Out-Null
    Get-ChildItem -LiteralPath $paths.controlRoot -Filter "admin-launch-*.bin" -File -ErrorAction SilentlyContinue |
        Where-Object LastWriteTimeUtc -lt (Get-Date).ToUniversalTime().AddMinutes(-10) |
        Remove-Item -Force -ErrorAction SilentlyContinue
    $secretPath = Join-Path $paths.controlRoot ("admin-launch-" + [guid]::NewGuid().ToString("N") + ".bin")
    $plainBytes = $utf8.GetBytes($Password)
    try {
        $protectedBytes = [Security.Cryptography.ProtectedData]::Protect(
            $plainBytes,
            $null,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        [IO.File]::WriteAllBytes($secretPath, $protectedBytes)
    }
    finally {
        if ($plainBytes) { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
    }
    return $secretPath
}

function Test-IsManagedProfile {
    param($Profile)
    $paths = Get-ManagedProfilePaths -Id ([string]$Profile.id)
    return [string]$Profile.commandChannel -eq "queue" -and
        [string]$Profile.statePath -ieq [string]$paths.statePath -and
        [string]$Profile.queueDir -ieq [string]$paths.queueDir
}

function Get-RunningProfileProcessInfo {
    param($Profile)
    return Get-PZProcessInfos | Where-Object {
        Test-PZProcessMatchesProfile -Process $_ -Profile $Profile
    } | Select-Object -First 1
}

function Get-PZProcessInfos {
    if (((Get-Date) - $script:pzProcessInfoCacheAt).TotalSeconds -lt 1) {
        return @($script:pzProcessInfoCache)
    }

    $runningJava = @(Get-Process -Name java, javaw -ErrorAction SilentlyContinue)
    if ($runningJava.Count -eq 0) {
        $script:pzProcessInfoCache = @()
        $script:pzProcessInfoCacheAt = Get-Date
        return @()
    }

    try {
        $script:pzProcessInfoCache = @(Get-CimInstance Win32_Process -Filter "Name='java.exe' OR Name='javaw.exe'" -OperationTimeoutSec 2 -ErrorAction Stop)
    }
    catch {
        $script:pzProcessInfoCache = @()
        Add-Audit -Remote "local" -Action "process-scan" -Detail $_.Exception.Message -Result "failed"
    }
    $script:pzProcessInfoCacheAt = Get-Date
    return @($script:pzProcessInfoCache)
}

function Find-PZSourceStartScript {
    param($Profile)
    $configured = ([string]$Profile.sourceStartScript).Trim()
    if ($configured) {
        if (-not (Test-Path -LiteralPath $configured -PathType Leaf)) { throw "原启动脚本不存在：$configured" }
        return [IO.Path]::GetFullPath($configured)
    }
    foreach ($name in @("StartServer64.bat", "StartServer64.cmd", "StartServer.bat", "StartServer.cmd")) {
        $candidate = Join-Path ([string]$Profile.runtimeRoot) $name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Get-PZBatchLaunchArguments {
    param([string]$Path)
    if ([IO.Path]::GetExtension($Path) -notin @(".bat", ".cmd")) {
        throw "原启动脚本目前支持 .bat 或 .cmd 文件。"
    }
    $batch = (Get-Content -LiteralPath $Path -Raw -Encoding Default) -replace '\^\s*\r?\n\s*', ' '
    $variables = @{}
    foreach ($line in $batch -split "`r?`n") {
        if ($line -match '(?i)^\s*(?:@?set)\s+"?([A-Za-z_][A-Za-z0-9_]*)=(.*?)"?\s*$') {
            $variables[$matches[1]] = $matches[2]
        }
    }
    $match = [regex]::Match($batch, '(?im)(?:^|\s)"?(?:\.\\)?jre64\\bin\\java(?:\.exe)?"?\s+(.+)$')
    if (-not $match.Success) { throw "无法从原启动脚本读取 Java 启动命令：$Path" }
    $arguments = $match.Groups[1].Value.Trim()
    foreach ($name in $variables.Keys) {
        $arguments = $arguments.Replace("%$name%", [string]$variables[$name])
    }
    $arguments = ($arguments -replace '(?i)(?:^|\s)%[1-9*](?=\s|$)', ' ') -replace '\s+', ' '
    $arguments = $arguments.Trim()
    if ($arguments -match '(?i)(?:^|\s)-adminpassword(?:=|\s)') { throw "启动批处理包含管理员密码，不能自动导入。" }
    return $arguments
}

function Get-ManagedLaunchArguments {
    param($Profile)
    $process = Get-RunningProfileProcessInfo -Profile $Profile
    if ($process) {
        $commandLine = ([string]$process.CommandLine).Trim()
        if ($commandLine -match '(?i)(?:^|\s)-adminpassword(?:=|\s)') {
            $existingPaths = Get-ManagedProfilePaths -Id ([string]$Profile.id)
            if (Test-Path -LiteralPath $existingPaths.profilePath -PathType Leaf) {
                try {
                    $existingManagedProfile = Get-Content -LiteralPath $existingPaths.profilePath -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ([string]$existingManagedProfile.javaPath -ieq [string]$Profile.javaPath -and
                        -not [string]::IsNullOrWhiteSpace([string]$existingManagedProfile.arguments) -and
                        [string]$existingManagedProfile.arguments -notmatch '(?i)(?:^|\s)-adminpassword(?:=|\s)') {
                        return [string]$existingManagedProfile.arguments
                    }
                }
                catch { }
            }
            throw "当前 Java 命令行包含一次性管理员密码，且没有可复用的无密码托管配置。"
        }
        $executablePattern = '^\s*(?:"[^"]+"|\S+)\s*'
        return [regex]::Replace($commandLine, $executablePattern, '', 1).Trim()
    }

    $paths = Get-ManagedProfilePaths -Id ([string]$Profile.id)
    $sourceStartScript = Find-PZSourceStartScript -Profile $Profile
    if ($sourceStartScript) {
        try { return Get-PZBatchLaunchArguments -Path $sourceStartScript }
        catch {
            if (-not (Test-Path -LiteralPath $paths.profilePath)) { throw }
        }
    }

    if (Test-Path -LiteralPath $paths.profilePath) {
        try {
            $managedProfile = Get-Content -LiteralPath $paths.profilePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$managedProfile.javaPath -ieq [string]$Profile.javaPath -and
                -not [string]::IsNullOrWhiteSpace([string]$managedProfile.arguments)) {
                return [string]$managedProfile.arguments
            }
        }
        catch { }
    }

    throw "未找到正在运行的 Java 启动参数，也无法从运行目录自动读取启动批处理。请填写原启动脚本后重试。"
}

function Enable-JvmGcTelemetry {
    param([string]$Arguments)
    if ([string]::IsNullOrWhiteSpace($Arguments) -or $Arguments -match '(?i)-Xlog:[^\s]*gc') { return $Arguments }
    $logging = "-Xlog:gc*,safepoint:file=logs/jvm-gc.log:time,uptime,level,tags:filecount=5,filesize=20M"
    if ($Arguments -notmatch '(?i)(?:^|\s)-Xlog:async(?:\s|$)') { $logging = "-Xlog:async $logging" }
    if ($Arguments -notmatch '(?i)\szombie\.network\.GameServer(?:\s|$)') { return $Arguments }
    return [regex]::Replace($Arguments, '(?i)\s+(?=zombie\.network\.GameServer(?:\s|$))', " $logging ", 1)
}

function Set-StreamingStabilityAgentArguments {
    param([string]$Arguments, $Profile)
    if ([string]::IsNullOrWhiteSpace($Arguments)) { throw "Java 启动参数为空。" }

    $agentPattern = '(?i)(?:^|\s)-javaagent:server-patches[/\\]PZServerStreamingStability-agent\.jar(?:=[^\s"]+)?'
    $result = ([regex]::Replace($Arguments, $agentPattern, ' ') -replace '\s+', ' ').Trim()
    $options = ([string]$Profile.streamingStabilityOptions).Trim()
    if ([string]::IsNullOrWhiteSpace($options)) { return $result }
    if ($result -notmatch '(?i)(?:^|\s)zombie\.network\.GameServer(?:\s|$)') {
        throw "Java 启动参数中缺少 zombie.network.GameServer。"
    }

    $agent = "-javaagent:server-patches/PZServerStreamingStability-agent.jar=$options"
    return [regex]::Replace($result, '(?i)(?=zombie\.network\.GameServer(?:\s|$))', "$agent ")
}

function Set-ManagedProfileIdentityArguments {
    param([string]$Arguments, $Profile)
    if ([string]::IsNullOrWhiteSpace($Arguments)) { throw "Java 启动参数为空。" }

    $dataRoot = [string]$Profile.dataRoot
    $serverName = [string]$Profile.serverName
    if ($dataRoot -match '["\r\n]' -or $serverName -match '["\s\r\n]') {
        throw "服务器数据目录或 servername 无法安全写入启动参数。"
    }

    $result = [regex]::Replace(
        $Arguments,
        '(?i)(?:^|\s)-cachedir(?:=|\s+)(?:"[^"]*"|\S+)',
        ' '
    )
    $result = [regex]::Replace(
        $result,
        '(?i)(?:^|\s)-servername(?:=|\s+)(?:"[^"]*"|\S+)',
        ' '
    )
    $result = ($result -replace '\s+', ' ').Trim()
    return "$result -cachedir=`"$dataRoot`" -servername $serverName"
}

function Ensure-ManagedProfile {
    param($Profile)
    if (-not (Test-IsManagedProfile -Profile $Profile)) { return }
    $paths = Get-ManagedProfilePaths -Id ([string]$Profile.id)
    New-Item -ItemType Directory -Path $managedRoot, $paths.controlRoot, $paths.queueDir, $paths.receiptDir -Force | Out-Null
    if (-not (Test-Path -LiteralPath $managedHostPath)) { throw "缺少通用托管脚本：$managedHostPath" }

    $arguments = Get-ManagedLaunchArguments -Profile $Profile
    $arguments = Set-ManagedProfileIdentityArguments -Arguments $arguments -Profile $Profile
    $arguments = Enable-JvmGcTelemetry -Arguments $arguments
    $arguments = Set-StreamingStabilityAgentArguments -Arguments $arguments -Profile $Profile
    $managedConfig = [ordered]@{
        id = [string]$Profile.id
        serverName = [string]$Profile.serverName
        dataRoot = [string]$Profile.dataRoot
        javaPath = [string]$Profile.javaPath
        workingDirectory = [string]$Profile.runtimeRoot
        arguments = $arguments
        queueDir = [string]$paths.queueDir
        receiptDir = [string]$paths.receiptDir
        statePath = [string]$paths.statePath
        consoleLog = [string]$Profile.consoleLog
        showConsole = [bool]$Profile.showConsole
    }
    [IO.File]::WriteAllText($paths.profilePath, ($managedConfig | ConvertTo-Json -Depth 5), $utf8)

    $startContent = @'
param([string]$AdminPasswordSecretPath)
$ErrorActionPreference = "Stop"
$hostScript = Join-Path (Split-Path -Parent $PSScriptRoot) "Run-ManagedPZHost.ps1"
$profilePath = Join-Path $PSScriptRoot "profile.json"
& $hostScript -ProfilePath $profilePath -AdminPasswordSecretPath $AdminPasswordSecretPath
'@
    $stopContent = @'
$ErrorActionPreference = "Stop"
$worker = Join-Path (Split-Path -Parent $PSScriptRoot) "Invoke-ManagedPZLifecycle.ps1"
$profilePath = Join-Path $PSScriptRoot "profile.json"
& $worker -Action stop -OperationId ([guid]::NewGuid().ToString("N")) -ProfilePath $profilePath
'@
    $restartContent = @'
$ErrorActionPreference = "Stop"
$worker = Join-Path (Split-Path -Parent $PSScriptRoot) "Invoke-ManagedPZLifecycle.ps1"
$profilePath = Join-Path $PSScriptRoot "profile.json"
& $worker -Action restart -OperationId ([guid]::NewGuid().ToString("N")) -ProfilePath $profilePath
'@
    [IO.File]::WriteAllText($paths.startScript, $startContent, $utf8)
    [IO.File]::WriteAllText($paths.stopScript, $stopContent, $utf8)
    [IO.File]::WriteAllText($paths.restartScript, $restartContent, $utf8)
}

function ConvertTo-ServerProfile {
    param($InputProfile)
    if (-not $InputProfile) { throw "缺少服务器配置内容。" }

    $id = ([string]$InputProfile.id).Trim().ToLowerInvariant()
    if ($id -notmatch '^[a-z0-9][a-z0-9_-]{0,31}$') { throw "服务器 ID 只能使用小写字母、数字、下划线和连字符。" }
    $name = Assert-SimpleText -Value ([string]$InputProfile.name) -Name "显示名称" -MaxLength 64
    $serverName = Assert-SimpleText -Value ([string]$InputProfile.serverName) -Name "servername" -MaxLength 64
    if ($serverName -notmatch '^[A-Za-z0-9_.-]+$') { throw "servername 格式无效。" }

    $kind = ([string]$InputProfile.kind).Trim().ToLowerInvariant()
    if ($kind -notin @("test", "production", "custom")) { throw "服务器类型无效。" }
    $channel = ([string]$InputProfile.commandChannel).Trim().ToLowerInvariant()
    if ($channel -notin @("readonly", "queue")) { throw "命令通道无效。" }

    $ports = @($InputProfile.ports | ForEach-Object { [int]$_ } | Select-Object -Unique)
    if ($ports.Count -lt 1 -or $ports.Count -gt 4 -or @($ports | Where-Object { $_ -lt 1 -or $_ -gt 65535 }).Count -gt 0) {
        throw "端口必须包含 1 至 4 个有效端口号。"
    }
    $maxPlayers = [int]$InputProfile.maxPlayers
    if ($maxPlayers -lt 1 -or $maxPlayers -gt 1000) { throw "玩家上限必须为 1 至 1000。" }

    $runtimeRoot = Normalize-AbsolutePath -Value $InputProfile.runtimeRoot -Name "运行目录" -Required
    $dataRoot = Normalize-AbsolutePath -Value $InputProfile.dataRoot -Name "数据目录" -Required
    $javaPath = Normalize-AbsolutePath -Value $InputProfile.javaPath -Name "Java 路径" -Required
    $consoleLog = Normalize-AbsolutePath -Value $InputProfile.consoleLog -Name "控制台日志路径" -Required
    $statePath = Normalize-AbsolutePath -Value $InputProfile.statePath -Name "状态文件路径"
    $queueDir = Normalize-AbsolutePath -Value $InputProfile.queueDir -Name "命令队列目录"
    $startScript = Normalize-AbsolutePath -Value $InputProfile.startScript -Name "启动脚本"
    $stopScript = Normalize-AbsolutePath -Value $InputProfile.stopScript -Name "停止脚本"
    $sourceStartScript = Normalize-AbsolutePath -Value $InputProfile.sourceStartScript -Name "原启动脚本"
    $streamingStabilityOptions = ([string]$InputProfile.streamingStabilityOptions).Trim()
    if ($streamingStabilityOptions.Length -gt 500 -or
        ($streamingStabilityOptions -and $streamingStabilityOptions -notmatch '^[A-Za-z][A-Za-z0-9]*(?:=[A-Za-z0-9.-]+)?(?:,[A-Za-z][A-Za-z0-9]*(?:=[A-Za-z0-9.-]+)?)*$')) {
        throw "流式防护参数格式无效，只能填写逗号分隔的 key=value。"
    }
    if ($channel -eq "queue" -and ([string]::IsNullOrWhiteSpace($queueDir) -or [string]::IsNullOrWhiteSpace($statePath) -or
        [string]::IsNullOrWhiteSpace($startScript) -or [string]::IsNullOrWhiteSpace($stopScript))) {
        $managedPaths = Get-ManagedProfilePaths -Id $id
        $queueDir = $managedPaths.queueDir
        $statePath = $managedPaths.statePath
        $startScript = $managedPaths.startScript
        $stopScript = $managedPaths.stopScript
    }
    foreach ($scriptPath in @($startScript, $stopScript)) {
        if ($scriptPath -and [IO.Path]::GetExtension($scriptPath) -ine ".ps1") { throw "启停脚本必须是 .ps1 文件。" }
    }

    $lanAddress = ([string]$InputProfile.lanAddress).Trim()
    if ($lanAddress.Length -gt 120 -or $lanAddress -match '[\r\n]') { throw "局域网地址格式无效。" }
    return [pscustomobject][ordered]@{
        id = $id
        name = $name
        kind = $kind
        serverName = $serverName
        runtimeRoot = $runtimeRoot
        dataRoot = $dataRoot
        javaPath = $javaPath
        statePath = $statePath
        consoleLog = $consoleLog
        queueDir = $queueDir
        commandChannel = $channel
        startScript = $startScript
        stopScript = $stopScript
        sourceStartScript = $sourceStartScript
        streamingStabilityOptions = $streamingStabilityOptions
        ports = $ports
        lanAddress = $lanAddress
        maxPlayers = $maxPlayers
        passwordRequired = [bool]$InputProfile.passwordRequired
        showConsole = [bool]$InputProfile.showConsole
    }
}

function Get-TextFileEncoding {
    param([byte[]]$Bytes)
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        return [Text.UTF8Encoding]::new($true)
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        return [Text.UnicodeEncoding]::new($false, $true)
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) {
        return [Text.UnicodeEncoding]::new($true, $true)
    }
    try {
        $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
        [void]$strictUtf8.GetString($Bytes)
        return $utf8
    }
    catch {
        return [Text.Encoding]::Default
    }
}

function Set-PZIniSettings {
    param(
        [string]$Path,
        [Collections.IDictionary]$Settings
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ updated = $false; path = $Path; reason = "missing"; backupPath = $null }
    }

    $bytes = [IO.File]::ReadAllBytes($Path)
    $encoding = Get-TextFileEncoding -Bytes $bytes
    $text = $encoding.GetString($bytes)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    foreach ($entry in $Settings.GetEnumerator()) {
        $pattern = "(?m)^$([regex]::Escape([string]$entry.Key))=[^\r\n]*"
        $value = "$($entry.Key)=$($entry.Value)"
        if ([regex]::IsMatch($text, $pattern)) {
            $text = [regex]::Replace($text, $pattern, $value)
        }
        else {
            if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $text += $newline }
            $text += $value + $newline
        }
    }

    $backupPath = "$Path.web-panel.bak"
    Copy-Item -LiteralPath $Path -Destination $backupPath -Force
    $tempPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($tempPath, $text, $encoding)
        Move-Item -LiteralPath $tempPath -Destination $Path -Force
    }
    finally { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
    return [pscustomobject]@{ updated = $true; path = $Path; reason = $null; backupPath = $backupPath }
}

function Sync-PZProfileGameSettings {
    param($Profile)
    $iniPath = Join-Path (Join-Path ([string]$Profile.dataRoot) "Server") "$([string]$Profile.serverName).ini"
    if (-not (Test-Path -LiteralPath $iniPath -PathType Leaf)) {
        return [pscustomobject]@{ updated = $false; path = $iniPath; reason = "missing" }
    }

    $ports = @($Profile.ports | ForEach-Object { [int]$_ })
    $udpPort = if ($ports.Count -ge 2) { $ports[1] } else { $ports[0] + 1 }
    if ($udpPort -gt 65535) { throw "默认端口过大，无法自动生成 UDPPort。" }
    $settings = [ordered]@{
        DefaultPort = $ports[0]
        UDPPort = $udpPort
        MaxPlayers = [int]$Profile.maxPlayers
    }

    return Set-PZIniSettings -Path $iniPath -Settings $settings
}

function Save-ServerProfiles {
    param([object[]]$Profiles, [string]$DefaultServer)
    if ($Profiles.Count -lt 1) { throw "至少需要保留一个服务器配置。" }
    if ($DefaultServer -notin @($Profiles | ForEach-Object { [string]$_.id })) { throw "默认服务器不存在。" }

    $nextConfig = [pscustomobject][ordered]@{ defaultServer = $DefaultServer; servers = $Profiles }
    $tempPath = "$profilesPath.$([guid]::NewGuid().ToString('N')).tmp"
    if (Test-Path -LiteralPath $profilesPath) { Copy-Item -LiteralPath $profilesPath -Destination $profilesBackupPath -Force }
    try {
        [IO.File]::WriteAllText($tempPath, ($nextConfig | ConvertTo-Json -Depth 8), $utf8)
        Move-Item -LiteralPath $tempPath -Destination $profilesPath -Force
    }
    finally { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }

    $script:profileConfig = $nextConfig
    $script:serverProfiles = @($Profiles)
    $script:statusCache = $null
    $script:statusCacheAt = [datetime]::MinValue
}

function Test-ProfileIdentityChanged {
    param($OldProfile, $NewProfile)
    foreach ($field in @("javaPath")) {
        $oldValue = $OldProfile.$field | ConvertTo-Json -Compress
        $newValue = $NewProfile.$field | ConvertTo-Json -Compress
        if ($oldValue -cne $newValue) { return $true }
    }
    return $false
}

function Get-PZCommandLineArgument {
    param([string]$CommandLine, [string]$Name)
    $match = [regex]::Match($CommandLine, "(?i)(?:^|\s)-$([regex]::Escape($Name))(?:=|\s+)(?:`"([^`"]+)`"|(\S+))")
    if (-not $match.Success) { return $null }
    if ($match.Groups[1].Success) { return $match.Groups[1].Value }
    return $match.Groups[2].Value
}

function Test-PZProcessMatchesProfile {
    param($Process, $Profile)
    if (-not $Process -or [string]$Process.Name -notmatch '^java(w)?\.exe$' -or
        [string]$Process.ExecutablePath -ine [string]$Profile.javaPath -or
        [string]$Process.CommandLine -notlike '*zombie.network.GameServer*') { return $false }
    $commandLine = [string]$Process.CommandLine
    $serverName = Get-PZCommandLineArgument -CommandLine $commandLine -Name "servername"
    if ([string]::IsNullOrWhiteSpace($serverName)) { $serverName = "servertest" }
    if ($serverName -ine [string]$Profile.serverName) { return $false }
    $dataRoot = Get-PZCommandLineArgument -CommandLine $commandLine -Name "cachedir"
    if ([string]::IsNullOrWhiteSpace($dataRoot)) { $dataRoot = Join-Path $env:USERPROFILE "Zomboid" }
    try { return [IO.Path]::GetFullPath($dataRoot) -ieq [IO.Path]::GetFullPath([string]$Profile.dataRoot) }
    catch { return $false }
}

function Read-PZIniSettings {
    param([string]$Path)
    $settings = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $settings }
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue) {
        if ($line -match '^([^#;=]+)=(.*)$') { $settings[$matches[1].Trim()] = $matches[2].Trim() }
    }
    return $settings
}

function Get-PrimaryLanAddress {
    $address = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
        Sort-Object InterfaceMetric |
        Select-Object -First 1 -ExpandProperty IPAddress
    if ($address) { return [string]$address }
    return "127.0.0.1"
}

function New-DiscoveredServerId {
    param([string]$ServerName, [string[]]$ReservedIds)
    $base = ($ServerName.ToLowerInvariant() -replace '[^a-z0-9_-]', '-') -replace '-+', '-'
    $base = $base.Trim('-_')
    if ([string]::IsNullOrWhiteSpace($base)) { $base = "pz-server" }
    if ($base.Length -gt 27) { $base = $base.Substring(0, 27).TrimEnd('-','_') }
    $id = $base
    $suffix = 2
    while ($id -in $ReservedIds) {
        $tail = "-$suffix"
        $prefixLength = [math]::Min($base.Length, 32 - $tail.Length)
        $id = $base.Substring(0, $prefixLength).TrimEnd('-','_') + $tail
        $suffix++
    }
    return $id
}

function Find-RunningPZServers {
    $results = @()
    $reservedIds = @($serverProfiles | ForEach-Object { [string]$_.id })
    $lanAddress = Get-PrimaryLanAddress
    $processes = Get-PZProcessInfos | Where-Object {
        $_.Name -match '^java(w)?\.exe$' -and $_.CommandLine -like '*zombie.network.GameServer*'
    }
    foreach ($process in $processes) {
        $javaPath = [string]$process.ExecutablePath
        if ([string]::IsNullOrWhiteSpace($javaPath) -or -not [IO.Path]::IsPathRooted($javaPath)) { continue }
        $runtimeRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $javaPath))
        $dataRoot = Get-PZCommandLineArgument -CommandLine ([string]$process.CommandLine) -Name "cachedir"
        if ([string]::IsNullOrWhiteSpace($dataRoot)) { $dataRoot = Join-Path $env:USERPROFILE "Zomboid" }
        $serverName = Get-PZCommandLineArgument -CommandLine ([string]$process.CommandLine) -Name "servername"
        if ([string]::IsNullOrWhiteSpace($serverName)) { $serverName = "servertest" }
        try {
            $dataRoot = [IO.Path]::GetFullPath($dataRoot)
            $javaPath = [IO.Path]::GetFullPath($javaPath)
            $runtimeRoot = [IO.Path]::GetFullPath($runtimeRoot)
        }
        catch { continue }

        $duplicate = $serverProfiles | Where-Object {
            [string]$_.serverName -ieq $serverName -and [string]$_.dataRoot -ieq $dataRoot
        } | Select-Object -First 1
        if ($duplicate) { continue }

        $iniPath = Join-Path $dataRoot "Server\$serverName.ini"
        $settings = Read-PZIniSettings -Path $iniPath
        $port = 16261
        if ($settings.DefaultPort -and -not [int]::TryParse([string]$settings.DefaultPort, [ref]$port)) { $port = 16261 }
        $maxPlayers = 32
        if ($settings.MaxPlayers -and -not [int]::TryParse([string]$settings.MaxPlayers, [ref]$maxPlayers)) { $maxPlayers = 32 }
        $maxPlayers = [math]::Max(1, [math]::Min(1000, $maxPlayers))
        $id = New-DiscoveredServerId -ServerName $serverName -ReservedIds $reservedIds
        $reservedIds += $id
        $profile = ConvertTo-ServerProfile -InputProfile ([pscustomobject]@{
            id = $id
            name = "$serverName（自动发现）"
            kind = "custom"
            serverName = $serverName
            runtimeRoot = $runtimeRoot
            dataRoot = $dataRoot
            javaPath = $javaPath
            statePath = $null
            consoleLog = (Join-Path $dataRoot "server-console.txt")
            queueDir = $null
            commandChannel = "readonly"
            startScript = $null
            stopScript = $null
            ports = @($port, ($port + 1))
            lanAddress = "$lanAddress`:$port"
            maxPlayers = $maxPlayers
            passwordRequired = -not [string]::IsNullOrEmpty([string]$settings.Password)
            showConsole = $false
        })
        $results += $profile
    }
    return @($results)
}

function Quote-PZ {
    param([string]$Value, [string]$Name, [int]$MaxLength = 128)
    $clean = Assert-SimpleText -Value $Value -Name $Name -MaxLength $MaxLength
    return '"' + $clean + '"'
}

function Read-Utf8Tail {
    param([string]$Path, [int]$MaxBytes = 131072)
    if (-not (Test-Path -LiteralPath $Path)) { return "" }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $readLength = [int][math]::Min([long]$MaxBytes, $stream.Length)
        if ($readLength -le 0) { return "" }
        [void]$stream.Seek($stream.Length - $readLength, [IO.SeekOrigin]::Begin)
        $bytes = [byte[]]::new($readLength)
        $offset = 0
        while ($offset -lt $readLength) {
            $count = $stream.Read($bytes, $offset, $readLength - $offset)
            if ($count -le 0) { break }
            $offset += $count
        }
        $start = 0
        if ($stream.Length -gt $readLength) {
            while ($start -lt $offset -and ($bytes[$start] -band 0xC0) -eq 0x80) { $start++ }
        }
        return $utf8.GetString($bytes, $start, $offset - $start)
    }
    finally { $stream.Dispose() }
}

function Get-OnlinePlayersFromConsoleLog {
    param([string]$Path, [int]$MaxBytes = 262144)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ known = $false; names = @(); steamIds = @{}; source = $null }
    }
    $tail = Read-Utf8Tail -Path $Path -MaxBytes $MaxBytes
    $lines = @($tail -split "`r?`n")
    for ($index = $lines.Count - 1; $index -ge 0; $index--) {
        if ($lines[$index] -notmatch 'Players connected \((\d+)\):') { continue }
        $expected = [int]$matches[1]
        $names = @()
        for ($playerIndex = $index + 1; $playerIndex -lt $lines.Count -and $names.Count -lt $expected; $playerIndex++) {
            if ($lines[$playerIndex] -notmatch '^\s*(?:>\s*)?-\s?(?<name>[^\r\n]+?)\s*$') { break }
            $names += $matches['name'].Trim()
        }
        if ($names.Count -eq $expected) {
            return [pscustomobject]@{ known = $true; names = @($names); steamIds = @{}; source = "console" }
        }
    }
    return [pscustomobject]@{ known = $false; names = @(); steamIds = @{}; source = $null }
}

function Get-OnlinePlayersFromUserLog {
    param($Profile, [datetime]$ServerStartTime)
    $logsPath = Join-Path ([string]$Profile.dataRoot) "Logs"
    if (-not (Test-Path -LiteralPath $logsPath -PathType Container)) {
        return [pscustomobject]@{ known = $false; names = @(); steamIds = @{}; source = $null }
    }
    $userLog = Get-ChildItem -LiteralPath $logsPath -Filter "*_user.txt" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.CreationTime -ge $ServerStartTime.AddMinutes(-5) -and $_.LastWriteTime -ge $ServerStartTime } |
        Sort-Object CreationTime -Descending | Select-Object -First 1
    if (-not $userLog) {
        return [pscustomobject]@{ known = $false; names = @(); steamIds = @{}; source = $null }
    }

    $cacheKey = $userLog.FullName.ToLowerInvariant()
    $connected = @{}
    $recognizedEvents = 0
    $stream = [IO.File]::Open($userLog.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $streamLength = $stream.Length
    $cached = $onlinePlayerCache[$cacheKey]
    if ($cached -and $cached.length -eq $streamLength) {
        $stream.Dispose()
        return $cached.snapshot
    }
    $reader = [IO.StreamReader]::new($stream, $utf8, $true)
    try {
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if ($line -match '\]\s+(\d{17})(?:\(owner=\d{17}\))? "([^"]+)" (?:allowed to join|fully connected)\b') {
                $recognizedEvents++
                $name = $matches[2]
                $connected[$name.ToLowerInvariant()] = [pscustomobject]@{ name = $name; steamId = $matches[1] }
            }
            elseif ($line -match '\]\s+(\d{17})(?:\(owner=\d{17}\))? "([^"]+)" disconnected player\b') {
                $recognizedEvents++
                $connected.Remove($matches[2].ToLowerInvariant())
            }
            elseif ($line -match '\]\s+Connection disconnect\b.*\bid=(\d{17})\.') {
                $recognizedEvents++
                $steamId = $matches[1]
                $disconnectedNames = @($connected.Values | Where-Object { $_.steamId -eq $steamId } | ForEach-Object { $_.name })
                foreach ($name in $disconnectedNames) { $connected.Remove($name.ToLowerInvariant()) }
            }
        }
    }
    finally { $reader.Dispose() }

    $names = @($connected.Values | ForEach-Object { $_.name } | Sort-Object)
    $steamIds = @{}
    foreach ($player in $connected.Values) { $steamIds[$player.name.ToLowerInvariant()] = $player.steamId }
    $snapshot = [pscustomobject]@{ known = ($recognizedEvents -gt 0); names = $names; steamIds = $steamIds; source = if ($recognizedEvents -gt 0) { "user-log" } else { $null } }
    $onlinePlayerCache[$cacheKey] = [pscustomobject]@{
        # PZ keeps this file open. Directory metadata may stay at zero bytes while
        # the open stream already contains new player events.
        length = $streamLength
        snapshot = $snapshot
    }
    return $snapshot
}

function Get-OnlinePlayerSnapshot {
    param($Profile, $Process)
    if (-not $Process) {
        return [pscustomobject]@{ known = $true; names = @(); steamIds = @{}; source = "stopped" }
    }
    $snapshot = Get-OnlinePlayersFromUserLog -Profile $Profile -ServerStartTime $Process.StartTime
    if ($snapshot.known) { return $snapshot }
    return Get-OnlinePlayersFromConsoleLog -Path ([string]$Profile.consoleLog)
}

function Get-ServerProfile {
    param([string]$Id, [switch]$AllowDefault)
    if ([string]::IsNullOrWhiteSpace($Id)) {
        if (-not $AllowDefault) { throw "请求必须指定 serverId。" }
        $Id = [string]$profileConfig.defaultServer
    }
    $profile = $serverProfiles | Where-Object { [string]$_.id -ceq $Id } | Select-Object -First 1
    if (-not $profile) { throw "未知服务器配置：$Id" }
    return $profile
}

function Get-ItemIndexPaths {
    param($Profile)
    $id = [string]$Profile.id
    return [pscustomobject]@{
        requestPath = Join-Path $itemIndexRoot "$id-request.json"
        outputPath = Join-Path $itemIndexRoot "$id.json"
        statusPath = Join-Path $itemIndexRoot "$id-status.json"
        stdoutPath = Join-Path $itemIndexRoot "$id-build.log"
        stderrPath = Join-Path $itemIndexRoot "$id-build-error.log"
    }
}

function Read-ItemIndexStatus {
    param($Profile)
    $paths = Get-ItemIndexPaths -Profile $Profile
    if (-not (Test-Path -LiteralPath $paths.statusPath)) { return $null }
    try { return Get-Content -LiteralPath $paths.statusPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { return $null }
}

function Start-ItemIndexBuild {
    param($Profile, [switch]$Force)
    if (-not $nodeRuntimePath) { throw "未找到 Node.js 运行环境，无法生成物品索引。" }
    if (-not (Test-Path -LiteralPath $itemIndexBuilderPath)) { throw "缺少物品索引器：$itemIndexBuilderPath" }

    $paths = Get-ItemIndexPaths -Profile $Profile
    New-Item -ItemType Directory -Path $itemIndexRoot -Force | Out-Null
    $status = Read-ItemIndexStatus -Profile $Profile
    if ($status -and [string]$status.state -eq "building" -and $status.pid) {
        $builderProcess = Get-Process -Id ([int]$status.pid) -ErrorAction SilentlyContinue
        if ($builderProcess) { return $status }
    }
    if (-not $Force -and $status -and [string]$status.state -eq "error") { return $status }
    if (-not $Force -and (Test-Path -LiteralPath $paths.outputPath)) { return $status }

    $request = [ordered]@{
        serverId = [string]$Profile.id
        runtimeRoot = [string]$Profile.runtimeRoot
        dataRoot = [string]$Profile.dataRoot
        serverName = [string]$Profile.serverName
        consoleLog = [string]$Profile.consoleLog
        outputPath = [string]$paths.outputPath
        statusPath = [string]$paths.statusPath
        previous = if ($status) { [ordered]@{
            count = $status.count
            stats = $status.stats
            completedAt = $status.completedAt
        } } else { $null }
    }
    [IO.File]::WriteAllText($paths.requestPath, ($request | ConvertTo-Json -Depth 4), $utf8)
    [IO.File]::WriteAllText($paths.statusPath, ([ordered]@{
        state = "building"
        serverId = [string]$Profile.id
        startedAt = (Get-Date).ToString("o")
        phase = "starting"
        phaseLabel = "准备扫描"
        cachedCount = if ($status) { $status.count } else { 0 }
        cachedStats = if ($status) { $status.stats } else { $null }
        cachedAt = if ($status) { $status.completedAt } else { $null }
    } | ConvertTo-Json), $utf8)
    Start-Process -FilePath $nodeRuntimePath -ArgumentList "`"$itemIndexBuilderPath`" `"$($paths.requestPath)`"" `
        -WorkingDirectory $root -WindowStyle Hidden -RedirectStandardOutput $paths.stdoutPath -RedirectStandardError $paths.stderrPath
    $script:itemIndexCache.Remove([string]$Profile.id)
    return Read-ItemIndexStatus -Profile $Profile
}

function Get-ItemIndexStatusPayload {
    param($Profile)
    $paths = Get-ItemIndexPaths -Profile $Profile
    $status = Read-ItemIndexStatus -Profile $Profile
    $cacheAvailable = Test-Path -LiteralPath $paths.outputPath -PathType Leaf
    $building = [bool]($status -and [string]$status.state -eq "building")
    $usingCachedMetadata = [bool]($status -and [string]$status.state -in @("building", "error") -and $cacheAvailable)
    $count = if ($usingCachedMetadata -and $status.cachedCount) { [int]$status.cachedCount } elseif ($status -and $status.count) { [int]$status.count } else { 0 }
    $stats = if ($usingCachedMetadata -and $status.cachedStats) { $status.cachedStats } elseif ($status) { $status.stats } else { $null }
    $generatedAt = if ($usingCachedMetadata -and $status.cachedAt) { [string]$status.cachedAt } elseif ($status) { [string]$status.completedAt } else { $null }
    return [ordered]@{
        ready = [bool]$cacheAvailable
        cacheAvailable = [bool]$cacheAvailable
        building = $building
        refreshing = [bool]($building -and $cacheAvailable)
        phase = if ($building) { [string]$status.phase } else { $null }
        phaseLabel = if ($building) { [string]$status.phaseLabel } else { $null }
        current = if ($building -and $status.current) { [int]$status.current } else { 0 }
        total = if ($building -and $status.total) { [int]$status.total } else { 0 }
        startedAt = if ($building) { [string]$status.startedAt } else { $null }
        generatedAt = $generatedAt
        count = $count
        stats = $stats
        error = if ($status -and [string]$status.state -eq "error") { [string]$status.error } else { $null }
    }
}

function Get-ItemCategory {
    param($Item)
    $raw = ([string]$Item.displayCategory).Trim()
    $type = ([string]$Item.itemType).Trim()
    $id = ([string]$Item.id).ToLowerInvariant()
    $name = (([string]$Item.nameZh) + " " + ([string]$Item.nameEn)).ToLowerInvariant()
    if ($raw -match "(?i)Ammo|Casing") { return "弹药" }
    if ($raw -match "(?i)WeaponPart") { return "武器配件" }
    if ($raw -match "(?i)Explosive") { return "爆炸物" }
    if ($raw -match "(?i)Weapon|Chainsaw") { return "武器" }
    if ($raw -match "(?i)Food|Water") { return "食物与饮品" }
    if ($raw -match "(?i)Cooking") { return "烹饪用品" }
    if ($raw -match "(?i)Clothing|Accessory|Appearance|ProtectiveGear|KATTAJ1") { return "服装与护具" }
    if ($raw -match "(?i)Bag|Container") { return "容器与背包" }
    if ($raw -match "(?i)FirstAid|Bandage|Wound") { return "医疗用品" }
    if ($raw -match "(?i)SkillBook|Literature|Cartography") { return "书籍与地图" }
    if ($raw -match "(?i)Electronics|Devices|Communications|LightSource|FireSource") { return "电子与照明" }
    if ($raw -match "(?i)Tool") { return "工具" }
    if ($raw -match "(?i)Material|RecipeResource") { return "材料" }
    if ($raw -match "(?i)Gardening|Farming") { return "农业" }
    if ($raw -match "(?i)Fishing") { return "钓鱼" }
    if ($raw -match "(?i)Trapping") { return "陷阱" }
    if ($raw -match "(?i)Camping") { return "露营" }
    if ($raw -match "(?i)VehicleMaintenance|CarPart|Mechanics") { return "车辆与零件" }
    if ($raw -match "(?i)Furniture|Household|Decoration") { return "家具与家居" }
    if ($raw -match "(?i)Entertainment|Memento|Curio|Art|Toy|Instrument|Sports") { return "娱乐与收藏" }
    if ($raw -match "(?i)Animal|HumanPart|Corpse|ZedDmg|Raccoon|Frog|Duck|Bear|Beaver|Fox|Bunny|Spider|Bug|Tail|Ears|Body") { return "生物相关" }
    if ($raw -match "(?i)Laboratory") { return "实验室用品" }
    if ($raw -match "(?i)Security") { return "钥匙与安保" }
    if ($raw -match "(?i)VFX|Hidden|Generic") { return "系统与调试" }
    if ($raw -match "(?i)Junk") { return "杂项" }
    if ($type -match "(?i)weaponpart") { return "武器配件" }
    if ($type -match "(?i)Weapon") { return "武器" }
    if ($type -match "(?i)Food") { return "食物与饮品" }
    if ($type -match "(?i)Clothing") { return "服装与护具" }
    if ($type -match "(?i)Literature|Map") { return "书籍与地图" }
    if ($type -match "(?i)Container") { return "容器与背包" }
    if ($type -match "(?i)Key") { return "钥匙与安保" }
    if ($type -match "(?i)Radio|AlarmClock") { return "电子与照明" }
    if ($raw) { return "其他 / Mod 自定义" }
    if ($id -match "ammo|bullet|shell|magazine") { return "弹药" }
    if ($id -match "gun|rifle|pistol|shotgun|revolver|firearm") { return "枪械" }
    if ($id -match "vehicle|carpart|tire|wheel|engine|brake|suspension|muffler") { return "车辆与零件" }
    if ($name -match "food|drink|water|食物|饮料|饮品") { return "食物与饮品" }
    return "其他"
}

function Read-ItemIndex {
    param($Profile)
    $paths = Get-ItemIndexPaths -Profile $Profile
    if (-not (Test-Path -LiteralPath $paths.outputPath)) { return $null }
    $item = Get-Item -LiteralPath $paths.outputPath
    $key = [string]$Profile.id
    $cached = $itemIndexCache[$key]
    if ($cached -and $cached.lastWriteTicks -eq $item.LastWriteTimeUtc.Ticks -and $cached.length -eq $item.Length) {
        return $cached.document
    }
    try { $document = Get-Content -LiteralPath $paths.outputPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { return $null }
    $searchRows = [Collections.Generic.List[object]]::new()
    $categorySet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $modSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($indexItem in @($document.items)) {
        $category = Get-ItemCategory -Item $indexItem
        $indexItem | Add-Member -NotePropertyName category -NotePropertyValue $category -Force
        [void]$categorySet.Add($category)
        if ([string]$indexItem.source -eq "mod" -and $indexItem.modId) { [void]$modSet.Add([string]$indexItem.modId) }
        $searchRows.Add([pscustomobject]@{
            item = $indexItem
            id = ([string]$indexItem.id).ToLowerInvariant()
            nameZh = ([string]$indexItem.nameZh).ToLowerInvariant()
            nameEn = ([string]$indexItem.nameEn).ToLowerInvariant()
            modId = ([string]$indexItem.modId).ToLowerInvariant()
            category = $category.ToLowerInvariant()
            source = ([string]$indexItem.source).ToLowerInvariant()
        })
    }
    $document | Add-Member -NotePropertyName _searchRows -NotePropertyValue $searchRows -Force
    $document | Add-Member -NotePropertyName _categories -NotePropertyValue @($categorySet | Sort-Object) -Force
    $document | Add-Member -NotePropertyName _mods -NotePropertyValue @($modSet | Sort-Object) -Force
    $itemIndexCache[$key] = [pscustomobject]@{
        lastWriteTicks = $item.LastWriteTimeUtc.Ticks
        length = $item.Length
        document = $document
    }
    return $document
}

function Get-ItemCatalogPayload {
    param($Profile, [string]$Query, [string]$Category, [string]$Source, [string]$ModId, [int]$Page = 1, [int]$PageSize = 60)
    $document = Read-ItemIndex -Profile $Profile
    if (-not $document) {
        $status = Start-ItemIndexBuild -Profile $Profile
        return [ordered]@{ ready = $false; building = [bool]($status -and [string]$status.state -eq "building"); total = 0; page = 1; pageSize = $PageSize; pages = 0; categories = @(); mods = @(); items = @() }
    }
    $needle = ([string]$Query).Trim().ToLowerInvariant()
    $categoryNeedle = ([string]$Category).Trim().ToLowerInvariant()
    $sourceNeedle = ([string]$Source).Trim().ToLowerInvariant()
    $modNeedle = ([string]$ModId).Trim().ToLowerInvariant()
    $filtered = [Collections.Generic.List[object]]::new()
    foreach ($row in $document._searchRows) {
        if ($needle -and -not ($row.id.Contains($needle) -or $row.nameZh.Contains($needle) -or $row.nameEn.Contains($needle) -or $row.modId.Contains($needle))) { continue }
        if ($categoryNeedle -and $row.category -ne $categoryNeedle) { continue }
        if ($sourceNeedle -and $row.source -ne $sourceNeedle) { continue }
        if ($modNeedle -and $row.modId -ne $modNeedle) { continue }
        $filtered.Add($row.item)
    }
    $total = $filtered.Count
    $pages = if ($total) { [math]::Ceiling($total / [double]$PageSize) } else { 0 }
    $safePage = if ($pages) { [math]::Max(1, [math]::Min($Page, $pages)) } else { 1 }
    $offset = ($safePage - 1) * $PageSize
    $pageItems = if ($total -gt $offset) { @($filtered | Select-Object -Skip $offset -First $PageSize) } else { @() }
    return [ordered]@{
        ready = $true
        total = $total
        count = [int]$document.count
        page = $safePage
        pageSize = $PageSize
        pages = [int]$pages
        generatedAt = [string]$document.generatedAt
        gameVersion = [string]$document.gameVersion
        categories = @($document._categories)
        mods = @($document._mods)
        items = $pageItems
    }
}

function Get-ItemSearchPayload {
    param($Profile, [string]$Query, [int]$Limit = 40)
    $document = Read-ItemIndex -Profile $Profile
    if (-not $document) {
        $status = Start-ItemIndexBuild -Profile $Profile
        return [ordered]@{
            ready = $false
            building = [bool]($status -and [string]$status.state -eq "building")
            error = if ($status -and [string]$status.state -eq "error") { [string]$status.error } else { $null }
            count = 0
            items = @()
        }
    }

    $needle = ([string]$Query).Trim().ToLowerInvariant()
    $matches = @()
    if ($needle) {
        $searchNeedles = @($needle)
        if ($needle.Length -ge 2 -and $needle.EndsWith("头")) { $searchNeedles += $needle.Substring(0, $needle.Length - 1) }
        $buckets = @(
            [Collections.Generic.List[object]]::new(), [Collections.Generic.List[object]]::new(),
            [Collections.Generic.List[object]]::new(), [Collections.Generic.List[object]]::new(),
            [Collections.Generic.List[object]]::new(), [Collections.Generic.List[object]]::new()
        )
        foreach ($row in $document._searchRows) {
            $matchedPrimary = $row.id.Contains($needle) -or $row.nameZh.Contains($needle) -or
                $row.nameEn.Contains($needle) -or $row.modId.Contains($needle)
            $matchedFallback = $false
            if (-not $matchedPrimary -and $searchNeedles.Count -gt 1) {
                $fallback = [string]$searchNeedles[1]
                $matchedFallback = $row.id.Contains($fallback) -or $row.nameZh.Contains($fallback) -or
                    $row.nameEn.Contains($fallback) -or $row.modId.Contains($fallback)
            }
            if (-not $matchedPrimary -and -not $matchedFallback) { continue }
            $rank = if ($row.id -eq $needle) { 0 } elseif ($row.nameZh -eq $needle -or $row.nameEn -eq $needle) { 1 } `
                elseif ($row.id.StartsWith($needle)) { 2 } elseif ($row.nameZh.StartsWith($needle) -or $row.nameEn.StartsWith($needle)) { 3 } `
                elseif ($matchedPrimary) { 4 } else { 5 }
            if ($buckets[$rank].Count -lt $Limit) { $buckets[$rank].Add($row.item) }
        }
        $resultList = [Collections.Generic.List[object]]::new()
        foreach ($bucket in $buckets) {
            foreach ($matchedItem in $bucket) {
                $resultList.Add($matchedItem)
                if ($resultList.Count -ge $Limit) { break }
            }
            if ($resultList.Count -ge $Limit) { break }
        }
        $matches = @($resultList)
    }
    $status = Read-ItemIndexStatus -Profile $Profile
    $refreshing = [bool]($status -and [string]$status.state -eq "building")
    return [ordered]@{
        ready = $true
        building = $refreshing
        refreshing = $refreshing
        phase = if ($refreshing -and $status.phase) { [string]$status.phase } else { $null }
        phaseLabel = if ($refreshing -and $status.phaseLabel) { [string]$status.phaseLabel } else { $null }
        startedAt = if ($refreshing -and $status.startedAt) { [string]$status.startedAt } else { $null }
        error = if ($status -and [string]$status.state -eq "error") { [string]$status.error } else { $null }
        count = [int]$document.count
        generatedAt = [string]$document.generatedAt
        gameVersion = [string]$document.gameVersion
        stats = $document.stats
        items = $matches
    }
}

function Get-ProcessorAffinityList {
    param($Process, [int]$LogicalProcessorCount)
    if (-not $Process) { return @() }
    try {
        $mask = [uint64]$Process.ProcessorAffinity.ToInt64()
        $result = [Collections.Generic.List[int]]::new()
        for ($index = 0; $index -lt [math]::Min($LogicalProcessorCount, 64); $index++) {
            if (($mask -band ([uint64]1 -shl $index)) -ne 0) { $result.Add($index) }
        }
        return @($result)
    }
    catch { return @() }
}

function Get-LogicalProcessorLoads {
    param([int]$LogicalProcessorCount)

    $samplesByIndex = @{}
    try {
        foreach ($sample in @(Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -OperationTimeoutSec 3 -ErrorAction Stop)) {
            $index = 0
            if (-not [int]::TryParse([string]$sample.Name, [ref]$index) -or $index -lt 0 -or $index -ge $LogicalProcessorCount) { continue }
            $samplesByIndex[$index] = [pscustomobject]@{
                usagePercent = [math]::Min(100, [math]::Max(0, [double]$sample.PercentProcessorTime))
                userPercent = [math]::Min(100, [math]::Max(0, [double]$sample.PercentUserTime))
                privilegedPercent = [math]::Min(100, [math]::Max(0, [double]$sample.PercentPrivilegedTime))
            }
        }
    }
    catch { }

    return @(for ($index = 0; $index -lt $LogicalProcessorCount; $index++) {
        $sample = $samplesByIndex[$index]
        [ordered]@{
            index = $index
            usagePercent = if ($sample) { [math]::Round([double]$sample.usagePercent, 1) } else { 0 }
            userPercent = if ($sample) { [math]::Round([double]$sample.userPercent, 1) } else { 0 }
            privilegedPercent = if ($sample) { [math]::Round([double]$sample.privilegedPercent, 1) } else { 0 }
        }
    })
}

function Get-SystemMetricsPayload {
    $now = Get-Date
    if ($systemMetricsCache -and ($now - $systemMetricsCacheAt).TotalSeconds -lt 5) { return $systemMetricsCache }

    if (-not $systemStaticCache) {
        $computer = Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 3
        $processors = @(Get-CimInstance Win32_Processor -OperationTimeoutSec 3)
        $operatingSystem = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 3
        $script:systemStaticCache = [pscustomobject]@{
            cpuName = [string]($processors | Select-Object -First 1).Name
            physicalCores = [int](($processors | Measure-Object NumberOfCores -Sum).Sum)
            logicalProcessors = [int]$computer.NumberOfLogicalProcessors
            memoryTotalBytes = [int64]$computer.TotalPhysicalMemory
            bootTime = [datetime]$operatingSystem.LastBootUpTime
        }
    }

    $operatingSystem = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 3
    $processorLoads = @(Get-CimInstance Win32_Processor -OperationTimeoutSec 3 | ForEach-Object { [double]$_.LoadPercentage })
    $cpuPercent = if ($processorLoads.Count) { [math]::Round((($processorLoads | Measure-Object -Average).Average), 1) } else { 0 }
    $logicalProcessorLoads = @(Get-LogicalProcessorLoads -LogicalProcessorCount $systemStaticCache.logicalProcessors)
    $memoryAvailable = [int64]$operatingSystem.FreePhysicalMemory * 1KB

    $disks = @()
    foreach ($disk in @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -OperationTimeoutSec 3)) {
        $disks += [ordered]@{
            drive = [string]$disk.DeviceID
            label = [string]$disk.VolumeName
            totalBytes = [int64]$disk.Size
            freeBytes = [int64]$disk.FreeSpace
            usedBytes = [int64]$disk.Size - [int64]$disk.FreeSpace
        }
    }

    $network = @()
    if (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue) {
        foreach ($adapter in @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" })) {
            try {
                $statistics = Get-NetAdapterStatistics -Name $adapter.Name -ErrorAction Stop
                $previous = $networkSamples[[string]$adapter.InterfaceGuid]
                $elapsed = if ($previous) { ($now - $previous.at).TotalSeconds } else { 0 }
                $receivedRate = if ($elapsed -gt 0) { [math]::Max(0, ([int64]$statistics.ReceivedBytes - [int64]$previous.received) / $elapsed) } else { 0 }
                $sentRate = if ($elapsed -gt 0) { [math]::Max(0, ([int64]$statistics.SentBytes - [int64]$previous.sent) / $elapsed) } else { 0 }
                $networkSamples[[string]$adapter.InterfaceGuid] = [pscustomobject]@{ at = $now; received = [int64]$statistics.ReceivedBytes; sent = [int64]$statistics.SentBytes }
                $network += [ordered]@{
                    name = [string]$adapter.Name
                    description = [string]$adapter.InterfaceDescription
                    receiveBytesPerSecond = [int64][math]::Round($receivedRate)
                    sendBytesPerSecond = [int64][math]::Round($sentRate)
                    bytesPerSecond = [int64][math]::Round($receivedRate + $sentRate)
                    linkSpeed = [string]$adapter.LinkSpeed
                }
            }
            catch { }
        }
    }

    $serverStates = if ($statusCache -and $statusCache.servers) { @($statusCache.servers) } else { @($serverProfiles | ForEach-Object { Get-ServerState -Profile $_ }) }
    $processTargets = @([pscustomobject]@{ kind = "panel"; serverId = $null; name = "Web 控制面板"; pid = $PID })
    foreach ($server in $serverStates | Where-Object { $_.javaPid }) {
        $processTargets += [pscustomobject]@{ kind = "server"; serverId = [string]$server.id; name = [string]$server.name; pid = [int]$server.javaPid }
    }
    $processes = @()
    $activePids = @{}
    foreach ($target in $processTargets) {
        $process = Get-Process -Id ([int]$target.pid) -ErrorAction SilentlyContinue
        if (-not $process) { continue }
        $activePids[[string]$process.Id] = $true
        $previous = $processCpuSamples[[string]$process.Id]
        $elapsed = if ($previous) { ($now - $previous.at).TotalSeconds } else { 0 }
        $cpuDelta = if ($previous) { [double]$process.CPU - [double]$previous.cpu } else { 0 }
        $processCpuPercent = if ($elapsed -gt 0) { [math]::Min(100, [math]::Max(0, ($cpuDelta / $elapsed / $systemStaticCache.logicalProcessors) * 100)) } else { 0 }
        $processCpuSamples[[string]$process.Id] = [pscustomobject]@{ at = $now; cpu = [double]$process.CPU }
        $processes += [ordered]@{
            kind = [string]$target.kind
            serverId = [string]$target.serverId
            name = [string]$target.name
            pid = [int]$process.Id
            cpuPercent = [math]::Round($processCpuPercent, 2)
            cpuSeconds = [math]::Round([double]$process.CPU, 1)
            workingSetBytes = [int64]$process.WorkingSet64
            peakWorkingSetBytes = [int64]$process.PeakWorkingSet64
            privateBytes = [int64]$process.PrivateMemorySize64
            threadCount = [int]$process.Threads.Count
            affinity = @(Get-ProcessorAffinityList -Process $process -LogicalProcessorCount $systemStaticCache.logicalProcessors)
        }
    }
    foreach ($samplePid in @($processCpuSamples.Keys)) {
        if (-not $activePids.ContainsKey([string]$samplePid)) { $processCpuSamples.Remove($samplePid) }
    }

    $script:systemMetricsCache = [ordered]@{
        ok = $true
        sampledAt = $now.ToString("o")
        host = [ordered]@{
            cpuName = $systemStaticCache.cpuName.Trim()
            physicalCores = $systemStaticCache.physicalCores
            logicalProcessors = $systemStaticCache.logicalProcessors
            cpuPercent = $cpuPercent
            memoryTotalBytes = $systemStaticCache.memoryTotalBytes
            memoryUsedBytes = $systemStaticCache.memoryTotalBytes - $memoryAvailable
            memoryAvailableBytes = $memoryAvailable
            uptimeSeconds = [int64]($now - $systemStaticCache.bootTime).TotalSeconds
        }
        disks = $disks
        network = $network
        processes = $processes
        logicalProcessors = $logicalProcessorLoads
        pollSeconds = 5
    }
    $script:systemMetricsCacheAt = $now
    return $systemMetricsCache
}

function Convert-JvmSizeToBytes {
    param([string]$Value)
    if ($Value -notmatch '^(?<number>\d+)(?<unit>[kKmMgGtT]?)$') { return $null }
    $multiplier = switch ($matches.unit.ToLowerInvariant()) {
        "k" { 1KB }
        "m" { 1MB }
        "g" { 1GB }
        "t" { 1TB }
        default { 1 }
    }
    return [int64]$matches.number * [int64]$multiplier
}

function Get-JvmGcLogPathArgument {
    param([string]$Arguments)
    if ([string]::IsNullOrWhiteSpace($Arguments)) { return $null }

    $decorators = 'none|time|utctime|uptime|timemillis|uptimemillis|timenanos|uptimenanos|hostname|pid|tid|level|tags|filecount|filesize'
    $pattern = '(?i)-Xlog:\S*?file=(?:"(?<quotedPath>[^"]+)"|(?<rawPath>[A-Za-z]:[/\\][^\s:"]+|\\\\[^\s:"]+|/[^\s:"]+|[^\s:"]+))(?=:(?:' + $decorators + ')(?:[=,:]|\s|$)|\s|$)'
    $match = [regex]::Match($Arguments, $pattern)
    if (-not $match.Success) { return $null }
    if ($match.Groups['quotedPath'].Success) { return [string]$match.Groups['quotedPath'].Value }
    return [string]$match.Groups['rawPath'].Value
}

function Get-JvmMemoryMetrics {
    param($Profile, $Process)
    if (-not $Process) {
        return [ordered]@{ available = $false; reason = "服务器未运行。" }
    }

    $processStartedAt = $Process.StartTime
    $processStartTicks = $processStartedAt.Ticks
    $processStartedAtText = $processStartedAt.ToString("o")
    $cacheKey = [string]$Profile.id
    $cached = $jvmMemoryCache[$cacheKey]
    if ($cached -and ([int]$cached.pid -ne [int]$Process.Id -or [int64]$cached.processStartTicks -ne $processStartTicks)) {
        $jvmMemoryCache.Remove($cacheKey)
        $cached = $null
    }

    $processInfo = Get-PZProcessInfos | Where-Object { [int]$_.ProcessId -eq [int]$Process.Id } | Select-Object -First 1
    $arguments = if ($processInfo) { [string]$processInfo.CommandLine } else { "" }
    $maxBytes = $null
    if ($arguments -match '(?i)(?:^|\s)-Xmx(?<size>\d+[kKmMgGtT]?)') {
        $maxBytes = Convert-JvmSizeToBytes -Value $matches.size
    }

    $relativeLogPath = Get-JvmGcLogPathArgument -Arguments $arguments
    if ([string]::IsNullOrWhiteSpace($relativeLogPath)) {
        return [ordered]@{
            available = $false
            maxBytes = $maxBytes
            processStartedAt = $processStartedAtText
            reason = "当前 Java 未开启 GC 日志；下次从面板启动后开始采集。"
        }
    }

    $logPath = if ([IO.Path]::IsPathRooted($relativeLogPath)) {
        [IO.Path]::GetFullPath($relativeLogPath)
    } else {
        [IO.Path]::GetFullPath((Join-Path ([string]$Profile.runtimeRoot) $relativeLogPath))
    }
    if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
        return [ordered]@{
            available = $false
            maxBytes = $maxBytes
            logPath = $logPath
            processStartedAt = $processStartedAtText
            reason = "GC 日志尚未生成；服务器运行并完成首次 GC 后会显示。"
        }
    }

    $file = Get-Item -LiteralPath $logPath
    $logStartedAt = $null
    try {
        $firstLogLine = Get-Content -LiteralPath $file.FullName -Encoding UTF8 -TotalCount 1
        if ($firstLogLine -match '^\[(?<timestamp>[^\]]+)\]') {
            $logStartedAt = [datetimeoffset]::Parse([string]$matches.timestamp)
        }
    } catch { }
    $logBelongsToProcess = if ($logStartedAt) {
        [math]::Abs(($logStartedAt.LocalDateTime - $processStartedAt).TotalSeconds) -le 5
    } else {
        $file.LastWriteTime -ge $processStartedAt.AddSeconds(-2)
    }
    if (-not $logBelongsToProcess) {
        return [ordered]@{
            available = $false
            maxBytes = $maxBytes
            logPath = $logPath
            processStartedAt = $processStartedAtText
            logStartedAt = if ($logStartedAt) { $logStartedAt.ToString("o") } else { $null }
            reason = "正在等待当前 Java 进程写入新的 GC 数据。"
        }
    }
    $logFiles = @(
        Get-ChildItem -LiteralPath $file.DirectoryName -Filter "$($file.Name)*" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq $file.Name -or ($_.Name -match "^$([regex]::Escape($file.Name))\.\d+$") } |
            Where-Object { $_.LastWriteTime -ge $processStartedAt.AddSeconds(-2) } |
            Sort-Object LastWriteTime, Name
    )
    if ($logFiles.Count -eq 0) { $logFiles = @($file) }
    $logSignature = ($logFiles | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTime.Ticks)" }) -join ";"
    if ($cached -and [int]$cached.pid -eq [int]$Process.Id -and
        [int64]$cached.processStartTicks -eq $processStartTicks -and [string]$cached.signature -eq $logSignature) {
        return $cached.payload
    }

    $currentUsedBytes = $null
    $peakUsedBytes = 0L
    $lastGcAt = $null
    $sampleCount = 0
    foreach ($logFile in $logFiles) {
        foreach ($line in Get-Content -LiteralPath $logFile.FullName -Encoding UTF8) {
            if ($line -match 'Max Capacity:\s*(?<size>\d+)M' -and -not $maxBytes) {
                $maxBytes = [int64]$matches.size * 1MB
            }
            if ($line -notmatch '\[gc,heap\s*\].*\bUsed:') { continue }
            $usedValues = @([regex]::Matches($line, '(?<size>\d+)M\s*\(\d+%\)') | ForEach-Object { [int64]$_.Groups['size'].Value })
            if ($usedValues.Count -lt 6) { continue }
            $sampleCount++
            $currentUsedBytes = $usedValues[3] * 1MB
            $eventPeakBytes = $usedValues[4] * 1MB
            if ($eventPeakBytes -gt $peakUsedBytes) { $peakUsedBytes = $eventPeakBytes }
            if ($line -match '^\[(?<timestamp>[^\]]+)\]') {
                try { $lastGcAt = ([datetime]::Parse([string]$matches.timestamp)).ToString("o") } catch { }
            }
        }
    }

    $payload = if ($null -eq $currentUsedBytes) {
        [ordered]@{
            available = $false
            maxBytes = $maxBytes
            logPath = $logPath
            processStartedAt = $processStartedAtText
            logStartedAt = if ($logStartedAt) { $logStartedAt.ToString("o") } else { $null }
            sampleCount = $sampleCount
            reason = "GC 日志已连接，等待首次完整堆统计。"
        }
    } else {
        [ordered]@{
            available = $true
            currentUsedBytes = [int64]$currentUsedBytes
            peakUsedBytes = [int64]$peakUsedBytes
            maxBytes = $maxBytes
            lastGcAt = $lastGcAt
            logPath = $logPath
            processStartedAt = $processStartedAtText
            logStartedAt = if ($logStartedAt) { $logStartedAt.ToString("o") } else { $null }
            sampleCount = $sampleCount
            source = "gc-log"
            note = "当前值为最近一次 GC 完成后的堆使用量；峰值为本次 Java 运行以来 GC 记录的最高值。"
        }
    }
    if ($payload.available) {
        $jvmMemoryCache[$cacheKey] = [pscustomobject]@{
            pid = [int]$Process.Id
            processStartTicks = $processStartTicks
            signature = $logSignature
            payload = $payload
        }
    }
    return $payload
}

function Get-ServerState {
    param($Profile)
    $state = $null
    if ($Profile.statePath -and (Test-Path -LiteralPath $Profile.statePath)) {
        try { $state = Get-Content -LiteralPath $Profile.statePath -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { $state = $null }
    }
    $process = $null
    if ($state -and $state.javaPid) {
        $stateProcessInfo = Get-PZProcessInfos | Where-Object { [int]$_.ProcessId -eq [int]$state.javaPid } | Select-Object -First 1
        if (Test-PZProcessMatchesProfile -Process $stateProcessInfo -Profile $Profile) {
            $process = Get-Process -Id ([int]$state.javaPid) -ErrorAction SilentlyContinue
        }
    }
    if (-not $process) {
        $processInfo = Get-RunningProfileProcessInfo -Profile $Profile
        if ($processInfo) { $process = Get-Process -Id ([int]$processInfo.ProcessId) -ErrorAction SilentlyContinue }
    }
    $ports = if ($process) { @($Profile.ports | ForEach-Object { [int]$_ }) } else { @() }
    $onlineSnapshot = Get-OnlinePlayerSnapshot -Profile $Profile -Process $process
    $onlineNames = @($onlineSnapshot.names)
    $onlineCount = $null
    $onlineText = $null
    if ($onlineSnapshot.known) {
        $onlineCount = $onlineNames.Count
        $onlineText = if ($onlineNames.Count) { $onlineNames -join "、" } else { "当前没有在线玩家" }
    }
    $hostProcess = if ($state -and $state.hostPid) { Get-Process -Id ([int]$state.hostPid) -ErrorAction SilentlyContinue } else { $null }
    $startupInProgress = [bool]($hostProcess -and $state -and [string]$state.status -in @("waiting-startup-lock", "starting"))
    $controllerAlive = [bool]($process -and $hostProcess -and $state -and [int]$state.javaPid -eq [int]$process.Id -and
        [string]$state.status -in @("starting", "running", "stopping"))
    $writable = [bool]($process -and [string]$Profile.commandChannel -eq "queue" -and $controllerAlive)
    $note = if ([string]$Profile.commandChannel -eq "readonly") {
        "该配置档没有受控命令通道，只读监控。"
    }
    elseif ($writable) {
        "受控命令通道已连接，可以执行管理操作。"
    }
    elseif ($startupInProgress) {
        if ([string]$state.status -eq "waiting-startup-lock") { "正在等待其他服务器完成 Steam 与 Workshop 初始化。" } else { "Java 已启动，正在等待服务器完成初始化。" }
    }
    elseif ($process -and (Test-IsManagedProfile -Profile $Profile)) {
        "自动托管配置已生成；当前实例仍由原方式启动，等待下次从面板启动后接管命令通道。"
    }
    elseif ($process) {
        "命令控制器未连接，当前实例保持只读。"
    }
    else {
        "服务器已停止，可从面板启动并建立受控命令通道。"
    }
    $startScriptReady = [bool]($Profile.startScript -and (Test-Path -LiteralPath ([string]$Profile.startScript) -PathType Leaf))
    $managedPaths = Get-ManagedProfilePaths -Id ([string]$Profile.id)
    $restartScriptReady = [bool]((Test-IsManagedProfile -Profile $Profile) -and [int]$state.protocolVersion -ge 2 -and
        (Test-Path -LiteralPath $managedPaths.restartScript -PathType Leaf))
    $canStart = [bool]($startScriptReady -and -not $process -and -not $startupInProgress)
    $adminSetupRequired = Test-PZAdminSetupRequired -Profile $Profile
    $startReason = if ($process) { "服务器进程仍在运行。" } elseif ($startupInProgress) { "服务器启动流程正在执行，不能重复启动。" } elseif (-not $Profile.startScript) { "未配置启动脚本。" } `
        elseif (-not $startScriptReady) { "启动脚本不存在：$($Profile.startScript)" } elseif ($adminSetupRequired) { "账号数据库不存在，启动时需要设置一次游戏内置 admin 密码。" } `
        else { "服务器已停止，可以从面板启动。" }
    $jvmMemory = Get-JvmMemoryMetrics -Profile $Profile -Process $process
    return [ordered]@{
        id = [string]$Profile.id
        name = [string]$Profile.name
        kind = [string]$Profile.kind
        serverName = [string]$Profile.serverName
        status = if ($process -and $state) { $state.status } elseif ($startupInProgress) { [string]$state.status } elseif ($process) { "running" } else { "stopped" }
        alive = [bool]$process
        javaPid = if ($process) { $process.Id } else { $null }
        memoryMB = if ($process) { [math]::Round($process.WorkingSet64 / 1MB) } else { 0 }
        memoryPeakMB = if ($process) { [math]::Round($process.PeakWorkingSet64 / 1MB) } else { 0 }
        privateMemoryMB = if ($process) { [math]::Round($process.PrivateMemorySize64 / 1MB) } else { 0 }
        jvmMemory = $jvmMemory
        cpuSeconds = if ($process) { [math]::Round($process.CPU, 1) } else { 0 }
        ports = $ports
        onlineKnown = [bool]$onlineSnapshot.known
        onlinePlayers = $onlineNames
        onlineSteamIds = $onlineSnapshot.steamIds
        onlineCount = $onlineCount
        onlineText = $onlineText
        startedAt = if ($state -and $state.startedAt) { $state.startedAt } elseif ($process) { $process.StartTime.ToString("o") } else { $null }
        logPath = [string]$Profile.consoleLog
        lanAddress = [string]$Profile.lanAddress
        maxPlayers = [int]$Profile.maxPlayers
        passwordRequired = [bool]$Profile.passwordRequired
        showConsole = [bool]$Profile.showConsole
        commandChannel = [string]$Profile.commandChannel
        writable = $writable
        canStart = $canStart
        startReason = $startReason
        adminSetupRequired = [bool]$adminSetupRequired
        canStop = [bool]($Profile.stopScript -and $writable)
        canRestart = [bool]($restartScriptReady -and $writable)
        note = $note
    }
}

function Get-MapResetPaths {
    param($Profile)
    $serverRoot = Join-Path $mapResetRoot ([string]$Profile.id)
    return [pscustomobject]@{
        root = $serverRoot
        configPath = Join-Path $serverRoot "config.json"
        statusPath = Join-Path $serverRoot "status.json"
        lastAuditPath = Join-Path $serverRoot "last-audit.json"
        operationsRoot = Join-Path $serverRoot "operations"
    }
}

function Assert-MapResetInteger {
    param([AllowNull()]$Value, [string]$Name, [int]$Minimum, [int]$Maximum)
    $number = 0
    if (-not [int]::TryParse([string]$Value, [ref]$number) -or $number -lt $Minimum -or $number -gt $Maximum) {
        throw "$Name 必须是 $Minimum 至 $Maximum 的整数。"
    }
    return $number
}

function Get-DefaultMapResetConfig {
    param($Profile)
    return [pscustomobject][ordered]@{
        version = 1
        serverId = [string]$Profile.id
        safehouseMarginChunks = 2
        playerMarginChunks = 8
        manualAreas = @()
        updatedAt = $null
    }
}

function Get-MapResetConfig {
    param($Profile)
    $paths = Get-MapResetPaths -Profile $Profile
    if (-not (Test-Path -LiteralPath $paths.configPath -PathType Leaf)) {
        return Get-DefaultMapResetConfig -Profile $Profile
    }
    try {
        $config = Get-Content -LiteralPath $paths.configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$config.serverId -cne [string]$Profile.id) { throw "配置所属服务器不匹配。" }
        return $config
    }
    catch { throw "地图刷新配置损坏：$($_.Exception.Message)" }
}

function ConvertTo-NormalizedMapResetConfig {
    param($Profile, $Body)
    $safehouseMargin = Assert-MapResetInteger -Value $Body.safehouseMarginChunks -Name "安全屋边距" -Minimum 0 -Maximum 64
    $playerMargin = Assert-MapResetInteger -Value $Body.playerMarginChunks -Name "人物边距" -Minimum 0 -Maximum 64
    $rawAreas = @($Body.manualAreas)
    if ($rawAreas.Count -gt 500) { throw "手动保护区域最多允许 500 项。" }
    $areas = @()
    for ($index = 0; $index -lt $rawAreas.Count; $index++) {
        $raw = $rawAreas[$index]
        $areas += [pscustomobject][ordered]@{
            name = Assert-SimpleText -Value ([string]$raw.name) -Name "第 $($index + 1) 个区域名称" -MaxLength 64
            x = Assert-MapResetInteger -Value $raw.x -Name "第 $($index + 1) 个区域 X" -Minimum -1000000 -Maximum 1000000
            y = Assert-MapResetInteger -Value $raw.y -Name "第 $($index + 1) 个区域 Y" -Minimum -1000000 -Maximum 1000000
            w = Assert-MapResetInteger -Value $raw.w -Name "第 $($index + 1) 个区域宽度" -Minimum 1 -Maximum 100000
            h = Assert-MapResetInteger -Value $raw.h -Name "第 $($index + 1) 个区域高度" -Minimum 1 -Maximum 100000
            marginChunks = Assert-MapResetInteger -Value $raw.marginChunks -Name "第 $($index + 1) 个区域边距" -Minimum 0 -Maximum 64
        }
    }
    return [pscustomobject][ordered]@{
        version = 1
        serverId = [string]$Profile.id
        safehouseMarginChunks = $safehouseMargin
        playerMarginChunks = $playerMargin
        manualAreas = $areas
        updatedAt = (Get-Date).ToString("o")
    }
}

function Save-MapResetConfig {
    param($Profile, $Config)
    $paths = Get-MapResetPaths -Profile $Profile
    New-Item -ItemType Directory -Path $paths.root -Force | Out-Null
    $temporaryPath = "$($paths.configPath).$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporaryPath, ($Config | ConvertTo-Json -Depth 8), $utf8)
        Move-Item -LiteralPath $temporaryPath -Destination $paths.configPath -Force
    }
    finally { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
}

function Get-MapResetConfigHash {
    param($Config)
    $relevant = [ordered]@{
        version = 1
        serverId = [string]$Config.serverId
        safehouseMarginChunks = [int]$Config.safehouseMarginChunks
        playerMarginChunks = [int]$Config.playerMarginChunks
        manualAreas = @($Config.manualAreas | ForEach-Object {
            [ordered]@{ name = [string]$_.name; x = [int]$_.x; y = [int]$_.y; w = [int]$_.w; h = [int]$_.h; marginChunks = [int]$_.marginChunks }
        })
    }
    $bytes = $utf8.GetBytes(($relevant | ConvertTo-Json -Depth 8 -Compress))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Write-MapResetJson {
    param([string]$Path, $Value)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 10), $utf8)
}

function Read-MapResetJson {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { return $null }
}

function Complete-MapResetStatus {
    param($Profile)
    $paths = Get-MapResetPaths -Profile $Profile
    $status = Read-MapResetJson -Path $paths.statusPath
    if (-not $status) { return $null }
    if ([string]$status.state -in @("running", "finalizing")) {
        $process = if ($status.pid) { Get-Process -Id ([int]$status.pid) -ErrorAction SilentlyContinue } else { $null }
        if ($process) { return $status }
        $exitCodePath = Join-Path ([string]$status.operationRoot) "exit-code.txt"
        if (-not (Test-Path -LiteralPath $exitCodePath -PathType Leaf)) {
            $status.state = "finalizing"
            return $status
        }
        $exitCode = 1
        [void][int]::TryParse((Get-Content -LiteralPath $exitCodePath -Raw -Encoding UTF8).Trim(), [ref]$exitCode)
        $reportDirectory = Get-ChildItem -LiteralPath ([string]$status.reportRoot) -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
        $summaryPath = if ($reportDirectory) { Join-Path $reportDirectory.FullName "summary.json" } else { $null }
        $summary = if ($summaryPath) { Read-MapResetJson -Path $summaryPath } else { $null }
        $status.finishedAt = (Get-Date).ToString("o")
        $status.exitCode = $exitCode
        $status.reportPath = if ($reportDirectory) { $reportDirectory.FullName } else { $null }
        $status.summaryPath = $summaryPath
        if ($exitCode -eq 0 -and $summary) {
            $status.state = "completed"
            $status.summary = $summary
            if ([string]$status.mode -eq "audit") {
                Write-MapResetJson -Path $paths.lastAuditPath -Value ([ordered]@{
                    operationId = [string]$status.operationId
                    configHash = [string]$status.configHash
                    completedAt = [string]$status.finishedAt
                    summaryPath = [string]$summaryPath
                    reportPath = [string]$status.reportPath
                })
            }
        }
        else {
            $status.state = "failed"
            $errorText = if (Test-Path -LiteralPath ([string]$status.stderrPath) -PathType Leaf) {
                (Get-Content -LiteralPath ([string]$status.stderrPath) -Raw -Encoding UTF8).Trim()
            } else { "后台工具未生成错误详情。" }
            if ([string]::IsNullOrWhiteSpace($errorText)) { $errorText = "后台工具执行失败，但没有输出错误详情。" }
            if ($errorText.Length -gt 4000) { $errorText = $errorText.Substring($errorText.Length - 4000) }
            $status.error = $errorText
        }
        Write-MapResetJson -Path $paths.statusPath -Value $status
        $history = $executionHistory | Where-Object { [string]$_.clientRequestId -ceq "map-reset:$($status.operationId)" } | Select-Object -First 1
        if ($history -and [string]$history.status -in @("queued", "running")) {
            $historyStatus = if ([string]$status.state -eq "completed") { "success" } else { "failed" }
            $operationLabel = if ([string]$status.mode -eq "audit") { "审计" } else { "执行" }
            $historyMessage = if ([string]$status.state -eq "completed") { "地图刷新$operationLabel 已完成。" } else { [string]$status.error }
            Set-ExecutionHistoryResult -Record $history -Status $historyStatus -ResultCode "map-reset-$($status.state)" -Message $historyMessage -Detail ([string]$status.reportPath)
            Save-ExecutionHistory
        }
    }
    return $status
}

function Get-MapResetPayload {
    param($Profile, $Session)
    $paths = Get-MapResetPaths -Profile $Profile
    $config = Get-MapResetConfig -Profile $Profile
    $status = Complete-MapResetStatus -Profile $Profile
    $lastAudit = Read-MapResetJson -Path $paths.lastAuditPath
    $lastAuditSummary = if ($lastAudit -and (Test-Path -LiteralPath ([string]$lastAudit.summaryPath) -PathType Leaf)) {
        Read-MapResetJson -Path ([string]$lastAudit.summaryPath)
    } else { $null }
    $serverState = Get-ServerState -Profile $Profile
    $configHash = Get-MapResetConfigHash -Config $config
    return [ordered]@{
        ok = $true
        serverId = [string]$Profile.id
        serverName = [string]$Profile.serverName
        saveRoot = Join-Path ([string]$Profile.dataRoot) "Saves\Multiplayer\$($Profile.serverName)"
        authorized = [bool]($Session -and [string]$Session.user.username -ieq "admin")
        pythonAvailable = [bool]$pythonRuntimePath
        toolAvailable = [bool]((Test-Path -LiteralPath $mapResetToolPath -PathType Leaf) -and (Test-Path -LiteralPath $mapResetRunnerPath -PathType Leaf))
        serverAlive = [bool]$serverState.alive
        lifecycleBusy = [bool](Get-ActiveLifecycleOperation -Profile $Profile)
        config = $config
        configHash = $configHash
        status = $status
        lastAudit = $lastAudit
        lastAuditSummary = $lastAuditSummary
        auditMatchesConfig = [bool]($lastAudit -and [string]$lastAudit.configHash -ceq $configHash -and (Test-Path -LiteralPath ([string]$lastAudit.summaryPath) -PathType Leaf))
    }
}

function ConvertTo-MapResetProcessArgument {
    param([string]$Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Start-MapResetOperation {
    param($Profile, $Config, [ValidateSet("audit", "apply")][string]$Mode, [string]$Confirmation)
    if (-not $pythonRuntimePath) { throw "未找到 Python 运行环境，无法启动地图刷新工具。" }
    if (-not (Test-Path -LiteralPath $mapResetToolPath -PathType Leaf) -or -not (Test-Path -LiteralPath $mapResetRunnerPath -PathType Leaf)) {
        throw "控制台内置地图刷新工具不完整。"
    }
    $paths = Get-MapResetPaths -Profile $Profile
    $current = Complete-MapResetStatus -Profile $Profile
    if ($current -and [string]$current.state -in @("running", "finalizing")) { throw "当前已有地图刷新任务正在执行。" }
    $saveRoot = Join-Path ([string]$Profile.dataRoot) "Saves\Multiplayer\$($Profile.serverName)"
    if (-not (Test-Path -LiteralPath (Join-Path $saveRoot "map_meta.bin") -PathType Leaf)) { throw "没有找到 B42 存档：$saveRoot" }
    $configHash = Get-MapResetConfigHash -Config $Config
    if ($Mode -eq "apply") {
        $serverState = Get-ServerState -Profile $Profile
        if ($serverState.alive) { throw "正式执行前必须先保存并停止所选游戏服务器。" }
        if (Get-ActiveLifecycleOperation -Profile $Profile) { throw "服务器生命周期操作仍在执行，请等待其结束。" }
        if ($Confirmation -cne [string]$Profile.serverName) { throw "确认文字必须与 serverName 完全一致：$($Profile.serverName)" }
        $lastAudit = Read-MapResetJson -Path $paths.lastAuditPath
        if (-not $lastAudit -or [string]$lastAudit.configHash -cne $configHash -or -not (Test-Path -LiteralPath ([string]$lastAudit.summaryPath) -PathType Leaf)) {
            throw "当前配置没有匹配的成功审计，请先保存配置并重新运行只读审计。"
        }
    }
    New-Item -ItemType Directory -Path $paths.operationsRoot -Force | Out-Null
    $operationId = [guid]::NewGuid().ToString("N")
    $operationRoot = Join-Path $paths.operationsRoot $operationId
    $reportRoot = Join-Path $operationRoot "reports"
    New-Item -ItemType Directory -Path $reportRoot -Force | Out-Null
    $manualAreasPath = Join-Path $operationRoot "manual-areas.json"
    Write-MapResetJson -Path $manualAreasPath -Value ([ordered]@{ protectAreas = @($Config.manualAreas) })
    Write-MapResetJson -Path (Join-Path $operationRoot "request.json") -Value ([ordered]@{
        operationId = $operationId; mode = $Mode; configHash = $configHash; config = $Config; createdAt = (Get-Date).ToString("o")
    })
    $stdoutPath = Join-Path $operationRoot "stdout.log"
    $stderrPath = Join-Path $operationRoot "stderr.log"
    $runnerArguments = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (ConvertTo-MapResetProcessArgument $mapResetRunnerPath),
        "-PythonPath", (ConvertTo-MapResetProcessArgument $pythonRuntimePath),
        "-ToolPath", (ConvertTo-MapResetProcessArgument $mapResetToolPath),
        "-SaveRoot", (ConvertTo-MapResetProcessArgument $saveRoot),
        "-ServerName", (ConvertTo-MapResetProcessArgument ([string]$Profile.serverName)),
        "-ManualAreas", (ConvertTo-MapResetProcessArgument $manualAreasPath),
        "-SafehouseMargin", [string]$Config.safehouseMarginChunks,
        "-PlayerMargin", [string]$Config.playerMarginChunks,
        "-ReportRoot", (ConvertTo-MapResetProcessArgument $reportRoot),
        "-Mode", $Mode
    )
    if ($Mode -eq "apply") { $runnerArguments += @("-Confirmation", (ConvertTo-MapResetProcessArgument $Confirmation)) }
    $process = Start-Process -FilePath "powershell.exe" -ArgumentList ($runnerArguments -join " ") -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    $status = [pscustomobject][ordered]@{
        operationId = $operationId; serverId = [string]$Profile.id; mode = $Mode; state = "running"; pid = $process.Id
        configHash = $configHash; startedAt = (Get-Date).ToString("o"); finishedAt = $null; exitCode = $null
        operationRoot = $operationRoot; reportRoot = $reportRoot; reportPath = $null; summaryPath = $null
        stdoutPath = $stdoutPath; stderrPath = $stderrPath; summary = $null; error = $null
    }
    Write-MapResetJson -Path $paths.statusPath -Value $status
    [void](Add-ExecutionHistoryRecord -ServerId ([string]$Profile.id) -Category "lifecycle" -Action "map-reset-$Mode" -Source "web" `
        -Summary $(if ($Mode -eq "audit") { "选择性区块刷新只读审计" } else { "选择性区块刷新正式执行" }) -Status "running" `
        -Message "后台任务已启动。" -ClientRequestId "map-reset:$operationId")
    return $status
}

function Get-PlayerDirectory {
    param($Profile)
    $state = Get-ServerState -Profile $Profile
    $online = @($state.onlinePlayers)

    $accounts = @()
    $databasePath = Join-Path $Profile.dataRoot "db\$($Profile.serverName).db"
    if ($nodeRuntimePath -and (Test-Path -LiteralPath $playerDbReaderPath) -and (Test-Path -LiteralPath $databasePath)) {
        try {
            $json = (& $nodeRuntimePath --no-warnings $playerDbReaderPath $databasePath 2>$null) -join "`n"
            if (-not [string]::IsNullOrWhiteSpace($json)) {
                $parsedAccounts = $json | ConvertFrom-Json
                foreach ($account in $parsedAccounts) { $accounts += $account }
            }
        }
        catch { $accounts = @() }
    }

    $onlineLookup = @{}
    foreach ($name in $online) { $onlineLookup[$name.ToLowerInvariant()] = $true }
    $players = @($accounts | ForEach-Object {
        [ordered]@{
            username = [string]$_.username
            role = [string]$_.role
            online = [bool]$onlineLookup.ContainsKey(([string]$_.username).ToLowerInvariant())
            lastConnection = [string]$_.lastConnection
            steamId = [string]$_.steamId
        }
    })
    foreach ($name in $online) {
        if (-not ($players | Where-Object { [string]$_.username -ceq $name })) {
            $steamId = $state.onlineSteamIds[$name.ToLowerInvariant()]
            $players += [ordered]@{ username = $name; role = "user"; online = $true; lastConnection = $null; steamId = $steamId }
        }
    }
    return [ordered]@{ onlineKnown = [bool]$state.onlineKnown; online = $online; players = $players; databaseAvailable = [bool]($accounts.Count -gt 0) }
}

function Get-PZPlayerDatabasePaths {
    param($Profile)
    return [pscustomobject]@{
        account = Join-Path ([string]$Profile.dataRoot) "db\$($Profile.serverName).db"
        players = Join-Path ([string]$Profile.dataRoot) "Saves\Multiplayer\$($Profile.serverName)\players.db"
    }
}

function Invoke-PZPlayerDataManager {
    param($Profile, [ValidateSet("inspect", "delete")][string]$Mode, [string]$SteamId)
    if ($SteamId -notmatch '^7656119\d{10}$') { throw "SteamID64 格式无效，应为 7656119 开头的 17 位数字。" }
    if (-not $nodeRuntimePath -or -not (Test-Path -LiteralPath $playerDataManagerPath -PathType Leaf)) {
        throw "缺少玩家数据库管理运行环境。"
    }
    $paths = Get-PZPlayerDatabasePaths -Profile $Profile
    $output = @(& $nodeRuntimePath --no-warnings $playerDataManagerPath $Mode $paths.account $paths.players $SteamId 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) {
        $detail = @($output | Select-Object -Last 8) -join "`n"
        throw "玩家数据库$($(if ($Mode -eq 'delete') { '删除' } else { '查询' }))失败：$detail"
    }
    $json = $output -join "`n"
    if ([string]::IsNullOrWhiteSpace($json)) { throw "玩家数据库工具没有返回结果。" }
    return $json | ConvertFrom-Json
}

function Backup-PZPlayerDatabases {
    param($Profile, [string]$SteamId, $Snapshot)
    $paths = Get-PZPlayerDatabasePaths -Profile $Profile
    $stamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
    $backupRoot = Join-Path $root "backups\player-data\$($Profile.id)\$SteamId\$stamp"
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    $copied = [Collections.Generic.List[string]]::new()
    foreach ($databasePath in @($paths.account, $paths.players)) {
        foreach ($candidate in @($databasePath, "$databasePath-wal", "$databasePath-shm", "$databasePath-journal")) {
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
            Copy-Item -LiteralPath $candidate -Destination (Join-Path $backupRoot ([IO.Path]::GetFileName($candidate))) -Force
            $copied.Add([IO.Path]::GetFileName($candidate))
        }
    }
    if ($copied.Count -eq 0) { throw "没有找到可备份的玩家数据库，已取消删除。" }
    $manifest = [ordered]@{
        createdAt = [DateTimeOffset]::Now.ToString("o")
        serverId = [string]$Profile.id
        serverName = [string]$Profile.serverName
        steamId = $SteamId
        accountCount = @($Snapshot.accounts).Count
        characterCount = @($Snapshot.characters).Count
        files = @($copied)
    }
    [IO.File]::WriteAllText((Join-Path $backupRoot "manifest.json"), ($manifest | ConvertTo-Json -Depth 5), $utf8)
    return $backupRoot
}

function Queue-Command {
    param($Profile, [string]$Command, [bool]$RequireReceipt = $false)
    if ([string]$Profile.commandChannel -ne "queue" -or [string]::IsNullOrWhiteSpace([string]$Profile.queueDir)) {
        throw "服务器 $($Profile.name) 没有可写命令通道。"
    }
    $state = Get-ServerState -Profile $Profile
    if (-not $state.alive) { throw "服务器 $($Profile.name) 当前未运行。" }
    if (-not $state.writable) { throw $state.note }
    if ($Command -match "[\r\n]" -or $Command.Length -gt 512) { throw "命令格式无效。" }
    New-Item -ItemType Directory -Path $Profile.queueDir -Force | Out-Null
    $request = [ordered]@{
        id = [guid]::NewGuid().ToString("N")
        createdAt = (Get-Date).ToString("o")
        command = $Command
        requireReceipt = $RequireReceipt
    }
    $name = "{0}-{1}.json" -f $request.createdAt.Replace(':','').Replace('.',''), $request.id
    [IO.File]::WriteAllText((Join-Path $Profile.queueDir $name), ($request | ConvertTo-Json -Compress), $utf8)
    return [pscustomobject]$request
}

function Resolve-Command {
    param($Body)
    $action = [string]$Body.action
    switch ($action) {
        "players" { return "players" }
        "connections" { return "list" }
        "stats" { return "stats" }
        "save" { return "save" }
        "showoptions" { return "showoptions" }
        "reloadoptions" { return "reloadoptions" }
        "worldgen-status" { return "worldgen status" }
        "help" { return "help" }
        "help-topic" {
            $topic = Assert-SimpleText -Value ([string]$Body.topic) -Name "命令名" -MaxLength 40
            if ($topic -notmatch '^[A-Za-z][A-Za-z0-9]*$') { throw "命令名格式无效。" }
            return "help $topic"
        }
        "check-mod-updates" { return "checkModsNeedUpdate" }
        "stoprain" { return "stoprain" }
        "worldgen" {
            $mode = [string]$Body.mode
            if ($mode -notin @("start", "recheck", "stop", "status")) { throw "无效世界生成操作。" }
            if ($mode -eq "recheck" -and $Body.confirm -ne "RECHECK_ALL") { throw "全量重检并生成需要输入指定确认文字。" }
            if ($mode -eq "start" -and $Body.confirm -ne "CONFIRM") { throw "启动世界生成需要二次确认。" }
            return "worldgen $mode"
        }
        "time-speed" {
            $period = [int]$Body.period
            if ($period -lt 1 -or $period -gt 100) { throw "时间倍率必须为 1 至 100。" }
            return "setTimeSpeed $period"
        }
        "change-option" {
            $name = Assert-SimpleText -Value ([string]$Body.name) -Name "选项名" -MaxLength 80
            if ($name -notmatch '^[A-Za-z][A-Za-z0-9_.-]*$') { throw "选项名格式无效。" }
            $value = Quote-PZ -Value ([string]$Body.value) -Name "选项值" -MaxLength 160
            if ($Body.confirm -ne "CONFIRM") { throw "修改服务器选项需要二次确认。" }
            return "changeoption $name $value"
        }
        "broadcast" {
            $message = Quote-PZ -Value ([string]$Body.message) -Name "广播内容" -MaxLength 240
            return "servermsg $message"
        }
        "access" {
            $user = Quote-PZ -Value ([string]$Body.username) -Name "用户名"
            $level = [string]$Body.level
            if ($level -eq "none") { $level = "user" }
            if ($level -notin @("admin", "moderator", "gm", "observer", "user")) { throw "无效权限等级。" }
            return "setaccesslevel $user `"$level`""
        }
        "kick" {
            $user = Quote-PZ -Value ([string]$Body.username) -Name "用户名"
            $reason = Quote-PZ -Value ([string]$Body.reason) -Name "原因" -MaxLength 120
            return "kick $user -r $reason"
        }
        "ban" {
            if ($Body.confirm -ne "CONFIRM") { throw "封禁操作需要二次确认。" }
            $user = Quote-PZ -Value ([string]$Body.username) -Name "用户名"
            $reason = Quote-PZ -Value ([string]$Body.reason) -Name "原因" -MaxLength 120
            $ip = if ([bool]$Body.banIp) { " -ip" } else { "" }
            return "banuser $user$ip -r $reason"
        }
        "unban" { return "unbanuser $(Quote-PZ -Value ([string]$Body.username) -Name '用户名')" }
        "steam-access" {
            $mode = [string]$Body.mode
            if ($mode -notin @("addsteamid", "removesteamid", "banid", "unbanid")) { throw "无效 SteamID 操作。" }
            $steamId = Assert-SimpleText -Value ([string]$Body.steamId) -Name "SteamID" -MaxLength 20
            if ($steamId -notmatch '^7656119\d{10}$') { throw "SteamID64 格式无效。" }
            if ($mode -eq "banid" -and $Body.confirm -ne "CONFIRM") { throw "封禁 SteamID 需要二次确认。" }
            return "$mode $steamId"
        }
        "ip-ban" {
            $mode = [string]$Body.mode
            if ($mode -notin @("banip", "unbanip")) { throw "无效 IP 操作。" }
            $ip = Assert-SimpleText -Value ([string]$Body.ip) -Name "IP 地址" -MaxLength 45
            $parsed = $null
            if (-not [Net.IPAddress]::TryParse($ip, [ref]$parsed)) { throw "IP 地址格式无效。" }
            if ($mode -eq "banip" -and $Body.confirm -ne "CONFIRM") { throw "封禁 IP 需要二次确认。" }
            return "$mode $ip"
        }
        "whitelist-remove" { return "removeuserfromwhitelist $(Quote-PZ -Value ([string]$Body.username) -Name '用户名')" }
        "user-account" {
            $mode = [string]$Body.mode
            if ($mode -notin @("adduser", "setpassword")) { throw "无效账号操作。" }
            $user = Quote-PZ -Value ([string]$Body.username) -Name "用户名"
            if ($mode -eq "adduser" -and [string]::IsNullOrWhiteSpace([string]$Body.password)) {
                return "adduser $user"
            }
            $password = Quote-PZ -Value ([string]$Body.password) -Name "用户密码" -MaxLength 128
            return "$mode $user $password"
        }
        "toggle" {
            $user = Quote-PZ -Value ([string]$Body.username) -Name "用户名"
            $feature = [string]$Body.feature
            if ($feature -notin @("godmodplayer", "invisibleplayer", "noclip", "voiceban")) { throw "无效玩家状态。" }
            $value = if ([bool]$Body.enabled) { "-true" } else { "-false" }
            return "$feature $user $value"
        }
        "teleport" {
            $from = Quote-PZ -Value ([string]$Body.username) -Name "玩家名"
            $to = Quote-PZ -Value ([string]$Body.target) -Name "目标玩家名"
            return "teleportplayer $from $to"
        }
        "additem" {
            $user = Quote-PZ -Value ([string]$Body.username) -Name "用户名"
            $item = Assert-SimpleText -Value ([string]$Body.item) -Name "物品类名" -MaxLength 100
            if ($item -notmatch '^[A-Za-z0-9_.-]+$') { throw "物品类名格式无效。" }
            $count = [int]$Body.count
            if ($count -lt 1 -or $count -gt 100) { throw "物品数量必须为 1 至 100。" }
            return "additem $user `"$item`" $count"
        }
        "addxp" {
            $user = Quote-PZ -Value ([string]$Body.username) -Name "用户名"
            $perk = Assert-SimpleText -Value ([string]$Body.perk) -Name "技能名" -MaxLength 64
            if ($perk -notmatch '^[A-Za-z][A-Za-z0-9_]*$') { throw "技能名格式无效。" }
            $amount = [int]$Body.amount
            if ($amount -lt 1 -or $amount -gt 100000) { throw "经验值必须为 1 至 100000。" }
            return "addxp $user $perk=$amount -true"
        }
        "addkey" {
            $user = Quote-PZ -Value ([string]$Body.username) -Name "用户名"
            $keyId = Assert-SimpleText -Value ([string]$Body.keyId) -Name "钥匙 ID" -MaxLength 32
            if ($keyId -notmatch '^\d+$') { throw "钥匙 ID 必须是数字。" }
            $name = Quote-PZ -Value ([string]$Body.name) -Name "钥匙名称" -MaxLength 80
            return "addkey $user `"$keyId`" $name"
        }
        "addvehicle" {
            $script = Assert-SimpleText -Value ([string]$Body.script) -Name "车辆脚本" -MaxLength 100
            if ($script -notmatch '^[A-Za-z0-9_.-]+$') { throw "车辆脚本格式无效。" }
            $target = Quote-PZ -Value ([string]$Body.target) -Name "玩家或坐标" -MaxLength 80
            return "addvehicle `"$script`" $target"
        }
        "horde" {
            $count = [int]$Body.count
            if ($count -lt 1 -or $count -gt 500) { throw "尸群数量必须为 1 至 500。" }
            $user = Quote-PZ -Value ([string]$Body.username) -Name "用户名"
            if ($Body.confirm -ne "CONFIRM") { throw "生成尸群需要二次确认。" }
            return "createhorde $count $user"
        }
        "safehouse" {
            $mode = [string]$Body.mode
            if ($mode -notin @("addtosafehouse", "kickfromsafehouse")) { throw "无效安全屋成员操作。" }
            $title = Quote-PZ -Value ([string]$Body.title) -Name "安全屋标题" -MaxLength 100
            $user = Quote-PZ -Value ([string]$Body.username) -Name "用户名"
            return "$mode $title $user"
        }
        "release-safehouse" {
            if ($Body.confirm -ne "CONFIRM") { throw "释放安全屋需要二次确认。" }
            return "releasesafehouse $(Quote-PZ -Value ([string]$Body.title) -Name '安全屋标题' -MaxLength 100)"
        }
        "remove-map-symbols" { return "removemapsymbolsforuser $(Quote-PZ -Value ([string]$Body.username) -Name '用户名')" }
        "lua-reload" {
            $mode = [string]$Body.mode
            if ($mode -notin @("reloadlua", "reloadalllua")) { throw "无效 Lua 重载操作。" }
            $file = Quote-PZ -Value ([string]$Body.file) -Name "Lua 文件" -MaxLength 180
            if ($Body.confirm -ne "CONFIRM") { throw "Lua 热重载需要二次确认。" }
            return "$mode $file"
        }
        "log-level" {
            $category = Assert-SimpleText -Value ([string]$Body.category) -Name "日志分类" -MaxLength 64
            if ($category -notmatch '^[A-Za-z][A-Za-z0-9_.-]*$') { throw "日志分类格式无效。" }
            $level = ([string]$Body.level).ToLowerInvariant()
            if ($level -notin @("trace", "debug", "general", "warning", "error", "off")) { throw "日志级别无效。" }
            return "log $category $level"
        }
        "event" {
            $eventName = [string]$Body.event
            switch ($eventName) {
                "chopper" { return "chopper" }
                "gunshot" { return "gunshot" }
                "stopweather" { return "stopweather" }
                "startrain" {
                    $value = [int]$Body.value
                    if ($value -lt 1 -or $value -gt 100) { throw "降雨强度必须为 1 至 100。" }
                    return "startrain $value"
                }
                "startstorm" {
                    $value = [int]$Body.value
                    if ($value -lt 1 -or $value -gt 168) { throw "风暴时长必须为 1 至 168 游戏小时。" }
                    return "startstorm $value"
                }
                "thunder" { return "thunder $(Quote-PZ -Value ([string]$Body.username) -Name '用户名')" }
                "lightning" { return "lightning $(Quote-PZ -Value ([string]$Body.username) -Name '用户名')" }
                default { throw "无效世界事件。" }
            }
        }
        default { throw "不允许的操作：$action" }
    }
}

function Resolve-AddItemBatch {
    param($Profile, $Body)

    $directory = Get-PlayerDirectory -Profile $Profile
    if (-not $directory.onlineKnown) {
        throw "当前无法确认在线玩家，不能发放物品。请刷新玩家列表后重试。"
    }

    $online = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($player in @($directory.players | Where-Object { [bool]$_.online })) {
        $name = [string]$player.username
        if (-not [string]::IsNullOrWhiteSpace($name) -and -not $online.ContainsKey($name)) {
            $online.Add($name, $name)
        }
    }

    $mode = ([string]$Body.targetMode).ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($mode)) { $mode = "single" }
    if ($mode -notin @("single", "selected", "all-online")) { throw "无效的物品发放对象范围。" }

    $requested = @()
    if ($mode -eq "all-online") {
        $requested = @($online.Values)
    }
    elseif ($null -ne $Body.usernames) {
        $requested = @($Body.usernames | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$Body.username)) {
        $requested = @([string]$Body.username)
    }

    if ($mode -eq "single" -and $requested.Count -ne 1) { throw "单人发放必须且只能选择一名在线玩家。" }
    if ($requested.Count -eq 0) {
        if ($mode -eq "all-online") { throw "当前没有在线玩家，不能执行全部在线发放。" }
        throw "请至少选择一名在线玩家。"
    }
    if ($requested.Count -gt 100) { throw "单次最多向 100 名在线玩家发放物品。" }

    $targets = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($requestedName in $requested) {
        $trimmed = $requestedName.Trim()
        if (-not $online.ContainsKey($trimmed)) { throw "玩家 $trimmed 当前不在线，请刷新在线玩家列表后重试。" }
        $canonicalName = $online[$trimmed]
        if ($seen.Add($canonicalName)) { $targets.Add($canonicalName) }
    }
    if ($targets.Count -eq 0) { throw "请至少选择一名在线玩家。" }

    $commands = @()
    foreach ($target in $targets) {
        $commands += Resolve-Command ([pscustomobject]@{
            action = "additem"
            username = $target
            item = [string]$Body.item
            count = [int]$Body.count
        })
    }
    return [pscustomobject]@{ commands = @($commands); targets = @($targets) }
}

function Get-BroadcastCommands {
    param([string]$Message, [int]$ChunkLength = 60)
    if ([string]::IsNullOrWhiteSpace($Message) -or $Message.Length -gt 1200 -or $Message.Contains('"')) {
        throw "广播内容不能为空或包含双引号，且最长 1200 个字符。"
    }
    $commands = @()
    foreach ($paragraph in @($Message -split "`r?`n")) {
        $remaining = $paragraph.Trim()
        while ($remaining.Length -gt 0) {
            $take = [math]::Min($ChunkLength, $remaining.Length)
            if ($take -lt $remaining.Length) {
                $candidate = $remaining.Substring(0, $take)
                $breakAt = $candidate.LastIndexOf(' ')
                if ($breakAt -ge [math]::Floor($ChunkLength * 0.55)) { $take = $breakAt }
            }
            $part = $remaining.Substring(0, $take).Trim()
            if (-not [string]::IsNullOrWhiteSpace($part)) {
                $commands += "servermsg $(Quote-PZ -Value $part -Name '广播内容' -MaxLength $ChunkLength)"
            }
            $remaining = $remaining.Substring($take).TrimStart()
        }
    }
    if ($commands.Count -eq 0) { throw "广播内容不能为空。" }
    if ($commands.Count -gt 30) { throw "广播拆分后超过 30 条，请缩短内容后重试。" }
    return @($commands)
}

function Get-NoticePaths {
    param($Profile)
    $luaRoot = Join-Path ([string]$Profile.dataRoot) "Lua"
    return [pscustomobject]@{
        root = $luaRoot
        queuePath = Join-Path $luaRoot "PZWebNotices-queue.txt"
        queueLockPath = Join-Path $luaRoot "PZWebNotices-queue.lock"
        receiptPath = Join-Path $luaRoot "PZWebNotices-receipts.log"
        receiptArchivePath = Join-Path $luaRoot "PZWebNotices-receipts.log.1"
        heartbeatPath = Join-Path $luaRoot "PZWebNotices-heartbeat.ini"
    }
}

function Get-NoticeHeartbeat {
    param($Profile)
    $paths = Get-NoticePaths -Profile $Profile
    $values = @{}
    if (Test-Path -LiteralPath $paths.heartbeatPath -PathType Leaf) {
        try {
            foreach ($line in Get-Content -LiteralPath $paths.heartbeatPath -Encoding UTF8 -ErrorAction Stop) {
                if ($line -match '^(?<name>[A-Za-z][A-Za-z0-9]*)=(?<value>.*)$') { $values[$matches.name] = $matches.value }
            }
        }
        catch { $values = @{} }
    }
    $updatedMs = 0L
    [void][long]::TryParse([string]$values.updatedMs, [ref]$updatedMs)
    $ageSeconds = $null
    if ($updatedMs -gt 0) {
        $ageSeconds = [math]::Max(0, [math]::Round(([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $updatedMs) / 1000, 1))
    }
    $noticeVersion = $null
    if ($values.version) {
        try { $noticeVersion = [version]([string]$values.version) }
        catch { $noticeVersion = $null }
    }
    $heartbeatStatus = if ($null -eq $ageSeconds) {
        "missing"
    }
    elseif ($ageSeconds -le 120) {
        "online"
    }
    elseif ($ageSeconds -le 300) {
        "stale"
    }
    else {
        "offline"
    }
    return [ordered]@{
        installed = Test-Path -LiteralPath (Join-Path $env:USERPROFILE "Zomboid\mods\PZWebNotices\42.20\mod.info") -PathType Leaf
        active = $heartbeatStatus -eq "online"
        stale = $heartbeatStatus -eq "stale"
        usable = $heartbeatStatus -in @("online", "stale")
        status = $heartbeatStatus
        version = if ($values.version) { [string]$values.version } else { $null }
        v3Compatible = [bool]($null -ne $noticeVersion -and $noticeVersion -ge [version]"0.2.3")
        updatedMs = if ($updatedMs -gt 0) { $updatedMs } else { $null }
        ageSeconds = $ageSeconds
        online = if ($values.ContainsKey("online")) { [int]$values.online } else { $null }
    }
}

function Assert-NoticeUtf8Text {
    param([string]$Value, [string]$Name, [int]$MaxBytes, [switch]$AllowNewlines)
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { throw "$Name 不能为空。" }
    if (-not $AllowNewlines -and $text -match "`r|`n") { throw "$Name 不能换行。" }
    if ($text -match '[\x00-\x08\x0B\x0C\x0E-\x1F]') { throw "$Name 不能包含控制字符。" }
    $byteCount = $utf8.GetByteCount($text)
    if ($byteCount -gt $MaxBytes) { throw "$Name 当前为 $byteCount 个 UTF-8 字节，最多允许 $MaxBytes 个字节。" }
    return $text
}

function Normalize-NoticeColor {
    param([string]$Value, [string]$Name)
    if ([string]::IsNullOrWhiteSpace($Value)) { return "-" }
    if ($Value -notmatch '^#[0-9A-Fa-f]{6}$') { throw "$Name 必须是 #RRGGBB 格式。" }
    return $Value.ToUpperInvariant()
}

function ConvertTo-NoticeQueueText {
    param([string]$Value)
    return ([string]$Value).Replace('%', '%25').Replace("`t", '%09').Replace("`r", '%0D').Replace("`n", '%0A')
}

function Wait-NoticeQueueUnlocked {
    param($Paths, [int]$TimeoutSeconds = 12)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (Test-Path -LiteralPath $Paths.queueLockPath -PathType Leaf) {
        $values = @{}
        try {
            foreach ($lockLine in Get-Content -LiteralPath $Paths.queueLockPath -Encoding UTF8 -ErrorAction Stop) {
                if ($lockLine -match '^(?<name>[A-Za-z][A-Za-z0-9]*)=(?<value>.*)$') { $values[$matches.name] = $matches.value }
            }
        }
        catch { return }
        if ([string]$values.locked -ne "1") { return }
        $expiresMs = 0L
        [void][long]::TryParse([string]$values.expiresMs, [ref]$expiresMs)
        if ($expiresMs -gt 0 -and [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() -ge $expiresMs) { return }
        if ((Get-Date) -ge $deadline) { throw "通知队列正在压缩，等待写锁超时。请稍后重试。" }
        Start-Sleep -Milliseconds 100
    }
}

function Add-NoticeQueueEntry {
    param(
        $Profile, [string]$Id, [string]$TargetType, [string]$TargetUsername,
        [string]$Style, [int]$Duration, [string]$TitleSize, [string]$BodySize,
        [string]$AccentColor, [string]$TextColor, [string]$Title, [string]$Message,
        [int]$ExpectedClients
    )
    $paths = Get-NoticePaths -Profile $Profile
    [IO.Directory]::CreateDirectory($paths.root) | Out-Null
    Wait-NoticeQueueUnlocked -Paths $paths
    $line = @(
        "v3", $Id, $TargetType, (ConvertTo-NoticeQueueText -Value $TargetUsername), $Style,
        $Duration.ToString([Globalization.CultureInfo]::InvariantCulture), $TitleSize, $BodySize,
        $AccentColor, $TextColor, (ConvertTo-NoticeQueueText -Value $Title),
        (ConvertTo-NoticeQueueText -Value $Message),
        $ExpectedClients.ToString([Globalization.CultureInfo]::InvariantCulture)
    ) -join "`t"
    $stream = [IO.File]::Open($paths.queuePath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        $bytes = $utf8.GetBytes($line + "`n")
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
}

function Invoke-ItemGrantNotification {
    param($Profile, $Body, [int]$TargetCount, [long]$LogCursor)

    $channel = ([string]$Body.notificationChannel).ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($channel)) { $channel = "none" }
    if ($channel -notin @("none", "native", "popup", "both")) { throw "物品发放通知通道无效。" }
    $result = [ordered]@{
        channel = $channel
        message = ""
        channels = @()
        requestIds = @()
        noticeId = ""
        expectedClients = 0
        warnings = @()
    }
    if ($channel -eq "none") { return [pscustomobject]$result }

    try {
        $message = ([string]$Body.notificationMessage).Trim()
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = "管理员已向 $TargetCount 名在线玩家发放 $([string]$Body.item) x$([int]$Body.count)。"
        }
        $message = Assert-NoticeUtf8Text -Value $message -Name "物品发放通知" -MaxBytes 4096 -AllowNewlines
        $result.message = $message
    }
    catch {
        $result.warnings += "附加通知内容无效：$($_.Exception.Message)"
        return [pscustomobject]$result
    }

    if ($channel -in @("native", "both")) {
        try {
            foreach ($command in @(Get-BroadcastCommands -Message $message)) {
                $queued = Queue-Command -Profile $Profile -Command $command -RequireReceipt:$true
                $result.requestIds += [string]$queued.id
                $commandRequests[[string]$queued.id] = [pscustomobject]@{
                    serverId = [string]$Profile.id
                    action = "broadcast"
                    command = [string]$command
                    queuedAt = [string]$queued.createdAt
                    logCursor = $LogCursor
                }
            }
            $result.channels += "原生全服广播"
        }
        catch { $result.warnings += "原生广播失败：$($_.Exception.Message)" }
    }

    if ($channel -in @("popup", "both")) {
        try {
            $duration = [int]$Body.notificationDuration
            if ($duration -eq 0) { $duration = 10 }
            if ($duration -lt 3 -or $duration -gt 300) { throw "弹窗时长必须为 3 至 300 秒。" }
            $state = Get-ServerState -Profile $Profile
            if (-not $state.alive) { throw "服务器当前未运行。" }
            $heartbeat = Get-NoticeHeartbeat -Profile $Profile
            if (-not $heartbeat.installed) { throw "本机未找到 PZWebNotices Mod。" }
            if (-not $heartbeat.usable -or -not $heartbeat.v3Compatible) { throw "PZWebNotices 当前没有可用心跳或版本低于 0.2.3。" }
            $result.noticeId = "notice-" + [guid]::NewGuid().ToString("N")
            $result.expectedClients = if ($state.onlineKnown) { [int]$state.onlineCount } else { 0 }
            Add-NoticeQueueEntry -Profile $Profile -Id ([string]$result.noticeId) -TargetType "all" -TargetUsername "" `
                -Style "success" -Duration $duration -TitleSize "medium" -BodySize "small" `
                -AccentColor "#4FC38A" -TextColor "#E1E6E9" -Title "物品发放通知" -Message $message `
                -ExpectedClients ([int]$result.expectedClients)
            $result.channels += "Mod 弹窗"
        }
        catch {
            $result.noticeId = ""
            $result.warnings += "Mod 弹窗失败：$($_.Exception.Message)"
        }
    }
    return [pscustomobject]$result
}

function Get-NoticeReceiptPayload {
    param($Profile, [string]$Id)
    if ($Id -notmatch '^(notice-)?[a-f0-9]{32}$') { throw "通知回执 ID 无效。" }
    $paths = Get-NoticePaths -Profile $Profile
    $deliveryStatus = $null
    $deliveredAt = $null
    $targetUsername = $null
    $expectedClients = $null
    $acknowledged = @{}
    $rejected = $null
    foreach ($receiptPath in @($paths.receiptPath, $paths.receiptArchivePath)) {
        if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) { continue }
        $receiptText = Read-Utf8Tail -Path $receiptPath -MaxBytes 262144
        foreach ($line in @($receiptText -split "`r?`n")) {
            $parts = @($line -split "`t", 5)
            if ($parts.Count -lt 4 -or [string]$parts[0] -cne $Id) { continue }
            $whenMs = 0L
            [void][long]::TryParse([string]$parts[2], [ref]$whenMs)
            switch ([string]$parts[1]) {
                "broadcast" {
                    $deliveryStatus = "broadcast"
                    $deliveredAt = if ($whenMs -gt 0) { [DateTimeOffset]::FromUnixTimeMilliseconds($whenMs).ToString("o") } else { $null }
                    $expectedClients = [int]$parts[3]
                }
                "directed" {
                    $deliveryStatus = "directed"
                    $deliveredAt = if ($whenMs -gt 0) { [DateTimeOffset]::FromUnixTimeMilliseconds($whenMs).ToString("o") } else { $null }
                    $expectedClients = [int]$parts[3]
                    $targetUsername = if ($parts.Count -ge 5) { [string]$parts[4] } else { $null }
                }
                "client" {
                    $username = if ($parts.Count -ge 5) { [string]$parts[4] } else { "unknown" }
                    if (-not [string]::IsNullOrWhiteSpace($username)) { $acknowledged[$username] = $true }
                }
                "rejected" { $rejected = [string]$parts[3] }
            }
        }
    }
    $heartbeat = Get-NoticeHeartbeat -Profile $Profile
    $acknowledgedPlayers = @($acknowledged.Keys | Sort-Object)
    return [ordered]@{
        ok = $true
        serverId = [string]$Profile.id
        id = $Id
        status = if ($rejected) { "rejected" } elseif ($deliveryStatus) { $deliveryStatus } else { "queued" }
        deliveredAt = $deliveredAt
        broadcastAt = if ($deliveryStatus -eq "broadcast") { $deliveredAt } else { $null }
        targetUsername = $targetUsername
        expectedClients = $expectedClients
        acknowledgedClients = $acknowledgedPlayers.Count
        acknowledgedPlayers = $acknowledgedPlayers
        error = $rejected
        channel = $heartbeat
    }
}

function Get-LogPayload {
    param(
        $Profile,
        [long]$After,
        [switch]$PreserveFromCursor,
        [int]$MaxBytes = 262144
    )
    $logPath = [string]$Profile.consoleLog
    if ([string]::IsNullOrWhiteSpace($logPath) -or -not (Test-Path -LiteralPath $logPath)) { return @{ text = ""; cursor = 0; reset = $true; hasMore = $false; length = 0 } }
    $item = Get-Item -LiteralPath $logPath
    $MaxBytes = [math]::Max(4096, [math]::Min(16777216, $MaxBytes))
    if ($PreserveFromCursor) {
        if ($After -lt 0 -or $After -gt $item.Length) {
            return @{ text = ""; cursor = $item.Length; reset = $true; hasMore = $false; length = $item.Length }
        }
        if ($After -eq $item.Length) {
            return @{ text = ""; cursor = $item.Length; reset = $false; hasMore = $false; length = $item.Length }
        }
        $readLength = [int][math]::Min([long]$MaxBytes, [long]($item.Length - $After))
        $stream = [IO.File]::Open($logPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            [void]$stream.Seek($After, [IO.SeekOrigin]::Begin)
            $bytes = [byte[]]::new($readLength)
            $offset = 0
            while ($offset -lt $readLength) {
                $count = $stream.Read($bytes, $offset, $readLength - $offset)
                if ($count -le 0) { break }
                $offset += $count
            }
            if (($After + $offset) -lt $item.Length) {
                for ($boundary = $offset - 1; $boundary -ge 0; $boundary -= 1) {
                    if ($bytes[$boundary] -eq 10) {
                        $offset = $boundary + 1
                        break
                    }
                }
            }
            $text = $utf8.GetString($bytes, 0, $offset)
        }
        finally { $stream.Dispose() }
        $cursor = $After + $offset
        return @{ text = $text; cursor = $cursor; reset = $false; hasMore = ($cursor -lt $item.Length); length = $item.Length }
    }
    if ($After -le 0 -or $After -gt $item.Length) {
        $text = Read-Utf8Tail -Path $logPath
        $lines = $text -split "`r?`n"
        if ($lines.Length -gt 350) { $text = $lines[($lines.Length - 350)..($lines.Length - 1)] -join "`n" }
        return @{ text = $text; cursor = $item.Length; reset = $true; hasMore = $false; length = $item.Length }
    }
    if ($After -eq $item.Length) { return @{ text = ""; cursor = $item.Length; reset = $false; hasMore = $false; length = $item.Length } }
    if (($item.Length - $After) -gt 262144) {
        return @{ text = (Read-Utf8Tail -Path $logPath); cursor = $item.Length; reset = $true; hasMore = $false; length = $item.Length }
    }
    $readLength = [int][math]::Min([long]262144, [long]($item.Length - $After))
    if ($readLength -le 0) { return @{ text = ""; cursor = $item.Length; reset = $false; hasMore = $false; length = $item.Length } }
    $stream = [IO.File]::Open($logPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        [void]$stream.Seek($After, [IO.SeekOrigin]::Begin)
        $bytes = [byte[]]::new($readLength)
        $offset = 0
        while ($offset -lt $readLength) {
            $count = $stream.Read($bytes, $offset, $readLength - $offset)
            if ($count -le 0) { break }
            $offset += $count
        }
        $text = $utf8.GetString($bytes, 0, $offset)
    }
    finally { $stream.Dispose() }
    return @{ text = $text; cursor = $item.Length; reset = $false; hasMore = $false; length = $item.Length }
}

function Get-LatestChatLog {
    param($Profile)
    $logsPath = Join-Path ([string]$Profile.dataRoot) "Logs"
    if (-not (Test-Path -LiteralPath $logsPath -PathType Container)) { return $null }
    return Get-ChildItem -LiteralPath $logsPath -Filter "*_chat.txt" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
}

function ConvertFrom-ChatLines {
    param([string[]]$Lines, [string]$FileId)
    $messages = @()
    foreach ($line in $Lines) {
        if ($line -match '^\[(?<timestamp>[^\]]+)\]\[info\]\s+Got message:ChatMessage\{chat=(?<channel>[^,}]+), author=''(?<author>.*?)'', text=''(?<text>.*)''\}\.$') {
            $messages += [ordered]@{
                id = "$FileId|$($matches.timestamp)|$($matches.channel)|$($matches.author)|$($matches.text)"
                timestamp = [string]$matches.timestamp
                channel = [string]$matches.channel
                author = [string]$matches.author
                text = [string]$matches.text
                kind = "player"
            }
            continue
        }
        $broadcastAuthor = $null
        if ($line -match '^\[(?<timestamp>[^\]]+)\]\s+Server alert message: ''(?<text>.*)'' by ''(?<author>.*)'' sent\.\.$') {
            $broadcastAuthor = [string]$matches.author
        }
        elseif ($line -match '^\[(?<timestamp>[^\]]+)\]\s+Server alert message: ''(?<text>.*)'' sent\.\.$') {
            $broadcastAuthor = "Web 面板"
        }
        if ($null -ne $broadcastAuthor) {
            $messages += [ordered]@{
                id = "$FileId|$($matches.timestamp)|broadcast|$broadcastAuthor|$($matches.text)"
                timestamp = [string]$matches.timestamp
                channel = "Broadcast"
                author = $broadcastAuthor
                text = [string]$matches.text
                kind = "broadcast"
            }
        }
    }
    return @($messages)
}

function Get-ChatPayload {
    param($Profile, [long]$After, [string]$RequestedFile)
    $chatLog = Get-LatestChatLog -Profile $Profile
    if (-not $chatLog) {
        return @{ messages = @(); cursor = 0; fileId = $null; reset = $true; available = $false; source = $null }
    }
    $fileId = [string]$chatLog.Name
    $sameFile = -not [string]::IsNullOrWhiteSpace($RequestedFile) -and $RequestedFile -ceq $fileId
    if (-not $sameFile) { $After = 0 }
    $overlapFromStart = $sameFile -and $After -gt 0 -and $After -le $chatLog.Length -and $After -le 4096
    $readAfter = if ($sameFile -and $After -gt 0 -and $After -le $chatLog.Length) { [math]::Max(0, $After - 4096) } else { 0 }
    $logPayload = Get-LogPayload -Profile ([pscustomobject]@{ consoleLog = $chatLog.FullName }) -After $readAfter
    $messages = ConvertFrom-ChatLines -Lines @([string]$logPayload.text -split "`r?`n") -FileId $fileId
    if ($messages.Count -gt 250) { $messages = @($messages[($messages.Count - 250)..($messages.Count - 1)]) }
    return @{
        messages = @($messages)
        cursor = [long]$logPayload.cursor
        fileId = $fileId
        reset = (-not $overlapFromStart -and [bool]$logPayload.reset) -or -not $sameFile
        available = $true
        source = $chatLog.FullName
        updatedAt = $chatLog.LastWriteTime.ToString("o")
    }
}

function Get-AddItemCommandParts {
    param([string]$Command)

    $match = [regex]::Match($Command, '^additem\s+(?:"(?<quotedUser>[^"]+)"|(?<plainUser>\S+))\s+(?:"(?<quotedItem>[^"]+)"|(?<plainItem>\S+))(?:\s+\d+)?$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) { return $null }
    return [pscustomobject]@{
        username = if ($match.Groups['quotedUser'].Success) { $match.Groups['quotedUser'].Value } else { $match.Groups['plainUser'].Value }
        item = if ($match.Groups['quotedItem'].Success) { $match.Groups['quotedItem'].Value } else { $match.Groups['plainItem'].Value }
    }
}

function New-AddItemOutcomeState {
    param([object[]]$Entries, [long]$Cursor = 0)

    $state = [pscustomobject]@{
        definitions = @{}
        waitingByCommand = @{}
        pending = [Collections.Generic.List[string]]::new()
        outcomes = @{}
        carry = ""
        cursor = $Cursor
        hasMore = $false
    }
    foreach ($entry in @($Entries)) {
        $id = [string]$entry.id
        $command = [string]$entry.command
        $parts = Get-AddItemCommandParts -Command $command
        if (-not $parts -or [string]::IsNullOrWhiteSpace($id)) { continue }
        $state.definitions[$id] = [pscustomobject]@{ id = $id; command = $command; username = [string]$parts.username; item = [string]$parts.item }
        if (-not $state.waitingByCommand.ContainsKey($command)) { $state.waitingByCommand[$command] = [Collections.Generic.Queue[string]]::new() }
        $state.waitingByCommand[$command].Enqueue($id)
    }
    return $state
}

function Update-AddItemOutcomeState {
    param($State, [string]$Text, [bool]$CompleteChunk = $true)

    $combined = [string]$State.carry + $Text
    $lines = @($combined -split "`r?`n")
    if (-not $CompleteChunk -and $lines.Count -gt 0) {
        $State.carry = [string]$lines[$lines.Count - 1]
        if ($lines.Count -eq 1) { $lines = @() }
        else { $lines = @($lines[0..($lines.Count - 2)]) }
    }
    else { $State.carry = "" }

    foreach ($line in @($Lines)) {
        $enteredMatch = [regex]::Match([string]$line, 'command entered via server console.*:\s*"(?<entered>.*)"\s*$')
        if ($enteredMatch.Success) {
            $entered = $enteredMatch.Groups['entered'].Value
            if ($State.waitingByCommand.ContainsKey($entered) -and $State.waitingByCommand[$entered].Count -gt 0) {
                $id = $State.waitingByCommand[$entered].Dequeue()
                $State.pending.Add($id)
                $State.outcomes[$id] = [pscustomobject]@{ status = 'pending'; resultCode = 'item-command-entered'; message = '游戏服务器已接收物品命令，正在等待发放结果。'; commandLine = [string]$line; resultLine = $null }
            }
            continue
        }

        $successMatch = [regex]::Match([string]$line, 'Item\s+(?<item>.+?)\s+Added in\s+(?<username>.+)''s inventory\.\s*$')
        if ($successMatch.Success) {
            $matchedIndex = -1
            for ($index = 0; $index -lt $State.pending.Count; $index += 1) {
                $definition = $State.definitions[$State.pending[$index]]
                if ([string]$definition.item -ieq $successMatch.Groups['item'].Value -and [string]$definition.username -ieq $successMatch.Groups['username'].Value) {
                    $matchedIndex = $index
                    break
                }
            }
            if ($matchedIndex -ge 0) {
                $id = $State.pending[$matchedIndex]
                $State.pending.RemoveAt($matchedIndex)
                $previous = $State.outcomes[$id]
                $State.outcomes[$id] = [pscustomobject]@{ status = 'success'; resultCode = 'item-added'; message = "已确认向 $($State.definitions[$id].username) 发放 $($State.definitions[$id].item)。"; commandLine = $previous.commandLine; resultLine = [string]$line }
            }
            continue
        }

        $failureCode = $null
        $failureMessage = $null
        if ([string]$line -match '>\s*No such user\.?\s*$') {
            $failureCode = 'player-not-found'
            $failureMessage = '游戏服务器返回：找不到该玩家，物品未发放。'
        }
        elseif ([string]$line -match '>\s*(?:No such item|Unknown item|Item .+ not found|Cannot find item)\.?\s*$') {
            $failureCode = 'item-not-found'
            $failureMessage = '游戏服务器返回：找不到该物品，物品未发放。'
        }
        if ($failureCode -and $State.pending.Count -gt 0) {
            $id = $State.pending[0]
            $State.pending.RemoveAt(0)
            $previous = $State.outcomes[$id]
            $State.outcomes[$id] = [pscustomobject]@{ status = 'failed'; resultCode = $failureCode; message = "$($State.definitions[$id].username)：$failureMessage"; commandLine = $previous.commandLine; resultLine = [string]$line }
        }
    }
    return $State
}

function Get-AddItemOutcomeMap {
    param([object[]]$Entries, [string[]]$Lines)

    $state = New-AddItemOutcomeState -Entries $Entries
    [void](Update-AddItemOutcomeState -State $state -Text (@($Lines) -join "`n") -CompleteChunk $true)
    return $state.outcomes
}

function Invoke-AddItemLogScan {
    param($Profile, [object[]]$Entries, [int]$MaxSegments = 4, [int]$SegmentBytes = 4194304)

    $entriesToScan = @($Entries | Where-Object {
        $tracked = $commandRequests[[string]$_.id]
        $tracked -and -not ($tracked.PSObject.Properties['itemOutcome'] -and $tracked.itemOutcome)
    })
    if ($entriesToScan.Count -eq 0) {
        $cached = @{}
        foreach ($entry in @($Entries)) {
            $tracked = $commandRequests[[string]$entry.id]
            if ($tracked -and $tracked.PSObject.Properties['itemOutcome'] -and $tracked.itemOutcome) { $cached[[string]$entry.id] = $tracked.itemOutcome }
        }
        return [pscustomobject]@{ outcomes = $cached; hasMore = $false; cursor = 0L; reads = 0 }
    }

    $state = $null
    foreach ($entry in $entriesToScan) {
        $tracked = $commandRequests[[string]$entry.id]
        if ($tracked.PSObject.Properties['itemScanState'] -and $tracked.itemScanState) { $state = $tracked.itemScanState; break }
    }
    if (-not $state) {
        $startCursor = [long](($entriesToScan | ForEach-Object { [long]$commandRequests[[string]$_.id].logCursor } | Measure-Object -Minimum).Minimum)
        $state = New-AddItemOutcomeState -Entries $entriesToScan -Cursor $startCursor
        foreach ($entry in $entriesToScan) {
            $tracked = $commandRequests[[string]$entry.id]
            $tracked | Add-Member -NotePropertyName itemScanState -NotePropertyValue $state -Force
        }
    }

    $reads = 0
    do {
        $payload = Get-LogPayload -Profile $Profile -After ([long]$state.cursor) -PreserveFromCursor -MaxBytes $SegmentBytes
        $reads += 1
        if ($payload.reset) {
            $state.cursor = [long]$payload.cursor
            $state.hasMore = $false
            $state.carry = ""
            break
        }
        [void](Update-AddItemOutcomeState -State $state -Text ([string]$payload.text) -CompleteChunk (-not [bool]$payload.hasMore))
        $state.cursor = [long]$payload.cursor
        $state.hasMore = [bool]$payload.hasMore
        $terminalCount = @($state.outcomes.Values | Where-Object { [string]$_.status -in @('success', 'failed') }).Count
    } while ($state.hasMore -and $reads -lt $MaxSegments -and $terminalCount -lt $state.definitions.Count)

    foreach ($id in @($state.outcomes.Keys)) {
        $outcome = $state.outcomes[$id]
        if ([string]$outcome.status -notin @('success', 'failed')) { continue }
        $tracked = $commandRequests[[string]$id]
        if ($tracked) { $tracked | Add-Member -NotePropertyName itemOutcome -NotePropertyValue $outcome -Force }
    }
    return [pscustomobject]@{ outcomes = $state.outcomes; hasMore = [bool]$state.hasMore; cursor = [long]$state.cursor; reads = $reads }
}

function Get-CommandResultPayload {
    param(
        $Profile,
        [string]$Id,
        [AllowNull()]$SharedLogPayload = $null,
        [AllowNull()][Collections.IDictionary]$AddItemOutcomes = $null,
        [bool]$ScanHasMore = $false
    )
    if ($Id -notmatch '^[a-f0-9]{32}$') { throw "命令回执 ID 无效。" }
    $tracked = $commandRequests[$Id]
    if ($tracked -and [string]$tracked.serverId -cne [string]$Profile.id) { throw "命令回执不属于当前服务器。" }

    $managedPaths = Get-ManagedProfilePaths -Id ([string]$Profile.id)
    $receiptPath = Join-Path $managedPaths.receiptDir "$Id.json"
    $receipt = $null
    if (Test-Path -LiteralPath $receiptPath) {
        try { $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }

    $output = @()
    $command = if ($tracked) { [string]$tracked.command } elseif ($receipt) { [string]$receipt.command } else { "" }
    $sensitiveCommand = $tracked -and [string]$tracked.action -in @("user-account", "player-password") -and [string]$tracked.command -ceq "[redacted]"
    $publicReceipt = $receipt
    if ($sensitiveCommand -and $receipt) {
        $publicReceipt = $receipt | ConvertTo-Json -Depth 6 | ConvertFrom-Json
        if ($publicReceipt.PSObject.Properties["command"]) { $publicReceipt.command = "[redacted]" }
    }
    $isModUpdateCheck = $tracked -and [string]$tracked.action -eq "check-mod-updates"
    $isAddItem = ($tracked -and [string]$tracked.action -eq "additem") -or [bool](Get-AddItemCommandParts -Command $command)
    $logPayload = $null
    if ($isAddItem -and $tracked -and $null -eq $AddItemOutcomes -and $Profile.consoleLog -and (Test-Path -LiteralPath ([string]$Profile.consoleLog))) {
        $scan = Invoke-AddItemLogScan -Profile $Profile -Entries @([pscustomobject]@{ id = $Id; command = $command })
        $AddItemOutcomes = $scan.outcomes
        $ScanHasMore = [bool]$scan.hasMore
    }
    elseif (-not $isAddItem -and $tracked -and $Profile.consoleLog -and (Test-Path -LiteralPath ([string]$Profile.consoleLog))) {
        $logPayload = if ($null -ne $SharedLogPayload) { $SharedLogPayload } else { Get-LogPayload -Profile $Profile -After ([long]$tracked.logCursor) }
        $afterCommand = $false
        foreach ($line in @([string]$logPayload.text -split "`r?`n")) {
            if ($line -match 'command entered via server console.*:\s*"(?<entered>.*)"\s*$') {
                if ([string]$matches.entered -ceq $command) {
                    $afterCommand = $true
                    $output += $line
                }
                elseif ($afterCommand) { break }
                continue
            }
            if (-not $afterCommand) { continue }
            if ($isModUpdateCheck) {
                if ($line -match 'CheckModsNeedUpdate:\s*(Checking\.{0,3}|Mods updated\.?|Mods need update\.?)\s*$') {
                    $output += $line
                    if ($line -match 'CheckModsNeedUpdate:\s*(Mods updated|Mods need update)\.?\s*$') { break }
                }
                continue
            }
            if (-not $isAddItem) {
                $output += $line
                if ($output.Count -ge 40) { break }
            }
        }
    }

    $elapsed = if ($tracked) { ((Get-Date) - [datetime]$tracked.queuedAt).TotalSeconds } else { 999 }
    $addItemOutcome = $null
    if ($isAddItem) {
        if ($tracked -and $tracked.PSObject.Properties['itemOutcome'] -and $tracked.itemOutcome) {
            $addItemOutcome = $tracked.itemOutcome
        }
        elseif ($AddItemOutcomes -and $AddItemOutcomes.Contains($Id)) {
            $addItemOutcome = $AddItemOutcomes[$Id]
        }
        elseif ($logPayload) {
            $singleMap = Get-AddItemOutcomeMap -Entries @([pscustomobject]@{ id = $Id; command = $command }) -Lines @([string]$logPayload.text -split "`r?`n")
            if ($singleMap.ContainsKey($Id)) { $addItemOutcome = $singleMap[$Id] }
        }
        if ($addItemOutcome) {
            $output = @($addItemOutcome.commandLine, $addItemOutcome.resultLine | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        }
    }
    $isAccessLevelCommand = ($tracked -and [string]$tracked.action -eq "access") -or $command -match '^setaccesslevel\s'
    $accessLevelFailure = $isAccessLevelCommand -and @($output | Where-Object { $_ -match "Access Level .* unknown|No such user|User .+ not found" }).Count -gt 0
    $failed = ($receipt -and [string]$receipt.status -eq "failed") -or ($addItemOutcome -and [string]$addItemOutcome.status -eq 'failed') -or $accessLevelFailure
    $hasServerOutput = $output.Count -gt 1
    $resultCode = $null
    $resultMessage = $null
    if ($isAddItem -and $addItemOutcome) {
        $resultCode = [string]$addItemOutcome.resultCode
        $resultMessage = [string]$addItemOutcome.message
    }
    elseif ($isModUpdateCheck) {
        if (@($output | Where-Object { $_ -match 'CheckModsNeedUpdate:\s*Mods need update\.?\s*$' }).Count -gt 0) {
            $resultCode = "mods-update-required"
            $resultMessage = "检测到 Mod 有新版本。此命令只负责检查，不会自动更新；请安排停服更新并重启服务器。"
        }
        elseif (@($output | Where-Object { $_ -match 'CheckModsNeedUpdate:\s*Mods updated\.?\s*$' }).Count -gt 0) {
            $resultCode = "mods-current"
            $resultMessage = "检查完成：当前服务器使用的 Mod 已是最新版本，无需更新。"
        }
        elseif ($hasServerOutput) {
            $resultCode = "mods-checking"
            $resultMessage = "服务器仍在检查 Mod 更新，请继续等待最终结果。"
        }
    }
    elseif ($accessLevelFailure) {
        $resultCode = "access-level-rejected"
        $resultMessage = "游戏服务器拒绝了访问级别修改，请核对玩家账号和权限等级。"
    }
    if ($tracked -and $hasServerOutput) {
        if (-not $tracked.PSObject.Properties["lastOutputCount"]) {
            $tracked | Add-Member -NotePropertyName "lastOutputCount" -NotePropertyValue $output.Count
            $tracked | Add-Member -NotePropertyName "lastOutputAt" -NotePropertyValue (Get-Date)
        }
        elseif ([int]$tracked.lastOutputCount -ne $output.Count) {
            $tracked.lastOutputCount = $output.Count
            $tracked.lastOutputAt = Get-Date
        }
    }
    $outputQuietSeconds = if ($tracked -and $tracked.PSObject.Properties["lastOutputAt"]) { ((Get-Date) - [datetime]$tracked.lastOutputAt).TotalSeconds } else { 0 }
    $responseSettled = if ($isAddItem) {
        $addItemOutcome -and [string]$addItemOutcome.status -in @('success', 'failed')
    } elseif ($isModUpdateCheck) {
        $resultCode -in @("mods-current", "mods-update-required")
    } else {
        $hasServerOutput -and $outputQuietSeconds -ge 1.5
    }
    $status = if ($failed) { "failed" } elseif ($responseSettled) { "response" } elseif ($receipt) { "delivered" } else { "queued" }
    $noOutputWaitSeconds = if ($tracked -and [string]$tracked.action -eq "check-mod-updates") { 300 } else { 12 }
    $done = $failed -or $responseSettled -or ($receipt -and $elapsed -ge $noOutputWaitSeconds -and -not ($isAddItem -and $ScanHasMore))
    $gameStatus = if (-not $isAddItem) { $null } elseif ($addItemOutcome -and [string]$addItemOutcome.status -in @('success', 'failed')) { [string]$addItemOutcome.status } elseif ($done) { 'unconfirmed' } elseif ($receipt) { 'pending' } else { 'queued' }
    if ($isAddItem -and $gameStatus -eq 'unconfirmed') {
        $resultCode = 'item-result-unconfirmed'
        $resultMessage = '物品命令已写入游戏服务器，但未在日志窗口内捕获到明确结果；请按“待确认”处理，不要直接重复发放。'
    }
    return [ordered]@{
        ok = $true
        serverId = [string]$Profile.id
        id = $Id
        command = $command
        status = $status
        done = [bool]$done
        noOutput = [bool]($done -and -not $failed -and -not $hasServerOutput)
        queuedAt = if ($tracked) { [string]$tracked.queuedAt } else { $null }
        action = if ($tracked) { [string]$tracked.action } else { $null }
        gameStatus = $gameStatus
        resultCode = $resultCode
        resultMessage = $resultMessage
        receipt = $publicReceipt
        output = @($output)
    }
}

function Get-CommandResultsPayload {
    param($Profile, [string[]]$Ids)

    $uniqueIds = @($Ids | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
    if ($uniqueIds.Count -eq 0 -or $uniqueIds.Count -gt 120) { throw "批量命令回执 ID 数量必须为 1 至 120。" }
    foreach ($id in $uniqueIds) {
        if ([string]$id -notmatch '^[a-f0-9]{32}$') { throw "命令回执 ID 无效。" }
        $tracked = $commandRequests[[string]$id]
        if ($tracked -and [string]$tracked.serverId -cne [string]$Profile.id) { throw "命令回执不属于当前服务器。" }
    }

    $sharedLogs = @{}
    $addItemScans = @{}
    foreach ($group in @($uniqueIds | ForEach-Object {
        $tracked = $commandRequests[[string]$_]
        if ($tracked) { [pscustomobject]@{ id = [string]$_; cursor = [long]$tracked.logCursor; action = [string]$tracked.action; command = [string]$tracked.command } }
    } | Group-Object cursor)) {
        $cursorKey = [string]$group.Name
        $itemEntries = @($group.Group | Where-Object { [string]$_.action -eq 'additem' })
        if ($itemEntries.Count -gt 0) {
            $addItemScans[$cursorKey] = Invoke-AddItemLogScan -Profile $Profile -Entries $itemEntries
        }
        if (@($group.Group | Where-Object { [string]$_.action -ne 'additem' }).Count -gt 0) {
            $sharedLogs[$cursorKey] = Get-LogPayload -Profile $Profile -After ([long]$group.Name)
        }
    }

    $results = @()
    foreach ($id in $uniqueIds) {
        $tracked = $commandRequests[[string]$id]
        $cursorKey = if ($tracked) { [string][long]$tracked.logCursor } else { $null }
        $sharedLog = if ($cursorKey -and $sharedLogs.ContainsKey($cursorKey)) { $sharedLogs[$cursorKey] } else { $null }
        $itemScan = if ($cursorKey -and $addItemScans.ContainsKey($cursorKey)) { $addItemScans[$cursorKey] } else { $null }
        $outcomeMap = if ($itemScan) { $itemScan.outcomes } else { $null }
        $results += Get-CommandResultPayload -Profile $Profile -Id ([string]$id) -SharedLogPayload $sharedLog -AddItemOutcomes $outcomeMap -ScanHasMore ([bool]($itemScan -and $itemScan.hasMore))
    }
    return [ordered]@{ ok = $true; serverId = [string]$Profile.id; count = $results.Count; results = @($results) }
}

function Get-CommandSubmissionPayload {
    param($Profile, [string]$Id)

    if ($Id -notmatch '^[a-f0-9]{32}$') { throw "命令提交 ID 无效。" }
    $record = $executionHistory | Where-Object {
        [string]$_.serverId -ceq [string]$Profile.id -and [string]$_.clientRequestId -ceq $Id
    } | Select-Object -Last 1
    if (-not $record) {
        return [ordered]@{ ok = $true; found = $false; serverId = [string]$Profile.id; submissionId = $Id }
    }
    return [ordered]@{
        ok = $true
        found = $true
        recovered = $true
        serverId = [string]$Profile.id
        submissionId = $Id
        action = [string]$record.action
        status = [string]$record.status
        resultCode = [string]$record.resultCode
        resultMessage = [string]$record.message
        requestId = if (@($record.requestIds).Count) { [string]@($record.requestIds)[0] } else { $null }
        requestIds = @($record.requestIds)
        itemRequestIds = @($record.requestIds)
        notificationRequestIds = @($record.auxiliaryRequestIds)
        noticeId = [string]$record.noticeId
        targetCount = @($record.requestIds).Count
        createdAt = [string]$record.createdAt
        updatedAt = [string]$record.updatedAt
    }
}

function Wait-ItemGrantSubmissionResult {
    param($Profile, [string]$SubmissionId, [string[]]$RequestIds, [int]$TimeoutMilliseconds = 5000)

    $deadline = (Get-Date).AddMilliseconds([math]::Max(250, [math]::Min(10000, $TimeoutMilliseconds)))
    do {
        Start-Sleep -Milliseconds 100
        try {
            $batch = Get-CommandResultsPayload -Profile $Profile -Ids $RequestIds
            $results = @($batch.results)
            $terminal = $results.Count -eq $RequestIds.Count -and @($results | Where-Object {
                -not [bool]$_.done -or [string]$_.gameStatus -notin @('success', 'failed', 'unconfirmed')
            }).Count -eq 0
            if ($terminal) {
                Invoke-ExecutionHistoryTick
                return [ordered]@{
                    settled = $true
                    submission = Get-CommandSubmissionPayload -Profile $Profile -Id $SubmissionId
                    results = $results
                }
            }
        }
        catch { }
    } while ((Get-Date) -lt $deadline)

    return [ordered]@{ settled = $false; submission = $null; results = @() }
}

function Send-MaintenanceAnnouncement {
    param($Profile, [string]$Title, [string]$Message)
    $serverState = Get-ServerState -Profile $Profile
    $channels = @()
    $warnings = @()
    $requestIds = @()
    $noticeId = ""
    $logCursor = 0L
    if ($Profile.consoleLog -and (Test-Path -LiteralPath ([string]$Profile.consoleLog))) {
        $logCursor = (Get-Item -LiteralPath ([string]$Profile.consoleLog)).Length
    }

    try {
        foreach ($command in @(Get-BroadcastCommands -Message $Message)) {
            $queued = Queue-Command -Profile $Profile -Command $command -RequireReceipt:$true
            $requestIds += [string]$queued.id
            $commandRequests[[string]$queued.id] = [pscustomobject]@{
                serverId = [string]$Profile.id
                action = "maintenance-broadcast"
                command = [string]$command
                queuedAt = [string]$queued.createdAt
                logCursor = $logCursor
            }
        }
        $channels += "native-broadcast"
    }
    catch { $warnings += "原生广播失败：$($_.Exception.Message)" }

    try {
        $heartbeat = Get-NoticeHeartbeat -Profile $Profile
        if (-not $heartbeat.usable) { throw "PZWebNotices 当前没有可用心跳。" }
        if (-not $heartbeat.v3Compatible) { throw "PZWebNotices 需要 0.2.3 或更高版本。" }
        $noticeId = "notice-" + [guid]::NewGuid().ToString("N")
        $expectedClients = if ($serverState.onlineKnown) { [int]$serverState.onlineCount } else { 0 }
        Add-NoticeQueueEntry -Profile $Profile -Id $noticeId -TargetType "all" -TargetUsername "" -Style "warning" -Duration 15 -TitleSize "medium" -BodySize "medium" -AccentColor "#E3A846" -TextColor "-" -Title $Title -Message $Message -ExpectedClients $expectedClients
        $channels += "popup"
    }
    catch { $warnings += "右下角弹窗失败：$($_.Exception.Message)" }

    return [pscustomobject]@{
        delivered = [bool]($channels.Count -gt 0)
        channels = @($channels)
        warnings = @($warnings)
        requestIds = @($requestIds)
        noticeId = $noticeId
    }
}

function Find-SteamCmdPath {
    param($Profile)
    $candidates = [Collections.Generic.List[string]]::new()
    $seen = @{}
    function Add-SteamCmdCandidate {
        param([string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path)) { return }
        try { $fullPath = [IO.Path]::GetFullPath($Path) } catch { return }
        if (-not $seen.ContainsKey($fullPath.ToLowerInvariant())) {
            $seen[$fullPath.ToLowerInvariant()] = $true
            $candidates.Add($fullPath)
        }
    }

    $configured = if ($Profile.PSObject.Properties["steamCmdPath"]) { [string]$Profile.steamCmdPath } else { "" }
    Add-SteamCmdCandidate $configured
    Add-SteamCmdCandidate (Join-Path $root "steamcmd\steamcmd.exe")
    Add-SteamCmdCandidate (Join-Path $root "steamcmd.exe")
    $command = Get-Command steamcmd.exe -ErrorAction SilentlyContinue
    if ($command) { Add-SteamCmdCandidate ([string]$command.Source) }

    $cursor = [string]$Profile.runtimeRoot
    for ($depth = 0; $depth -lt 6 -and -not [string]::IsNullOrWhiteSpace($cursor); $depth++) {
        Add-SteamCmdCandidate (Join-Path $cursor "steamcmd.exe")
        Add-SteamCmdCandidate (Join-Path $cursor "steamcmd\steamcmd.exe")
        try { $parent = Split-Path -Parent $cursor } catch { $parent = "" }
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
    foreach ($drive in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        Add-SteamCmdCandidate (Join-Path $drive.Root "SteamCMD\steamcmd.exe")
        Add-SteamCmdCandidate (Join-Path $drive.Root "steamcmd\steamcmd.exe")
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Get-PZInstallLayout {
    param($Profile, [string]$SteamCmdPath = "")
    $runtimeRoot = [IO.Path]::GetFullPath([string]$Profile.runtimeRoot).TrimEnd('\', '/')
    $installMode = "force-install-dir"
    $manifestPath = Join-Path $runtimeRoot "steamapps\appmanifest_380870.acf"
    if (-not [string]::IsNullOrWhiteSpace($SteamCmdPath)) {
        $steamCmdRoot = Split-Path -Parent ([IO.Path]::GetFullPath($SteamCmdPath))
        $libraryRuntime = Join-Path $steamCmdRoot "steamapps\common\Project Zomboid Dedicated Server"
        if ([string]::Equals($runtimeRoot, $libraryRuntime.TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)) {
            $installMode = "steam-library"
            $manifestPath = Join-Path $steamCmdRoot "steamapps\appmanifest_380870.acf"
        }
    }
    return [pscustomobject][ordered]@{
        installMode = $installMode
        runtimeRoot = $runtimeRoot
        manifestPath = $manifestPath
    }
}

function Get-PZLocalBuildInfo {
    param($Profile, [string]$SteamCmdPath = "")
    $layout = Get-PZInstallLayout -Profile $Profile -SteamCmdPath $SteamCmdPath

    $buildId = $null
    $branch = $null
    $manifestPath = $null
    if (Test-Path -LiteralPath $layout.manifestPath -PathType Leaf) {
        try { $manifest = Get-Content -LiteralPath $layout.manifestPath -Raw -Encoding UTF8 } catch { $manifest = "" }
        if ($manifest -match '(?m)^\s*"appid"\s+"380870"\s*$') {
            $manifestPath = $layout.manifestPath
        }
        if ($manifestPath) {
        if ($manifest -match '(?m)^\s*"buildid"\s+"(?<id>\d+)"\s*$') { $buildId = [string]$matches.id }
        if ($manifest -match '(?m)^\s*"BetaKey"\s+"(?<branch>[^"]+)"\s*$') { $branch = [string]$matches.branch }
        }
    }

    $version = $null
    if ($Profile.consoleLog -and (Test-Path -LiteralPath ([string]$Profile.consoleLog) -PathType Leaf)) {
        try {
            foreach ($line in @(Get-Content -LiteralPath ([string]$Profile.consoleLog) -Encoding UTF8 -TotalCount 500)) {
                if ($line -match '(?i)\bversion=(?<version>\d+\.\d+(?:\.\d+)?)\b') { $version = [string]$matches.version }
            }
        }
        catch { }
    }
    return [pscustomobject][ordered]@{
        buildId = $buildId
        branch = if ($branch) { $branch } else { "public" }
        version = $version
        manifestPath = $manifestPath
        expectedManifestPath = $layout.manifestPath
        installMode = $layout.installMode
    }
}

function Invoke-SteamCmdMetadataQuery {
    param([string]$SteamCmdPath)
    $lines = @(& $SteamCmdPath +login anonymous +app_info_update 1 +app_info_print 380870 +quit 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    $output = $lines -join "`n"
    if ($exitCode -ne 0) { throw "SteamCMD 查询失败，退出码 $exitCode。`n$(@($lines | Select-Object -Last 20) -join "`n")" }
    $match = [regex]::Match($output, '(?s)"branches"\s*\{.*?"public"\s*\{.*?"buildid"\s*"(?<id>\d+)"')
    if (-not $match.Success) { throw "SteamCMD 已返回，但没有找到 public 分支 BuildID。" }
    return [pscustomobject][ordered]@{
        buildId = [string]$match.Groups['id'].Value
        detail = @($lines | Where-Object { $_ -match 'Update state|Logged in OK|Waiting for user info|buildid|ERROR|Success' } | Select-Object -Last 30) -join "`n"
    }
}

function Get-PZSaveBackupPayload {
    param($Profile)
    $iniPath = Join-Path (Join-Path ([string]$Profile.dataRoot) "Server") "$([string]$Profile.serverName).ini"
    if (-not (Test-Path -LiteralPath $iniPath -PathType Leaf)) {
        throw "找不到服务器 INI：$iniPath"
    }

    $settings = Read-PZIniSettings -Path $iniPath
    $saveMinutes = 0
    $backupMinutes = 0
    $backupCount = 5
    if ($settings.ContainsKey("SaveWorldEveryMinutes")) {
        [void][int]::TryParse([string]$settings.SaveWorldEveryMinutes, [ref]$saveMinutes)
    }
    if ($settings.ContainsKey("BackupsPeriod")) {
        [void][int]::TryParse([string]$settings.BackupsPeriod, [ref]$backupMinutes)
    }
    if ($settings.ContainsKey("BackupsCount")) {
        [void][int]::TryParse([string]$settings.BackupsCount, [ref]$backupCount)
    }
    $saveMinutes = [math]::Max(0, $saveMinutes)
    $backupMinutes = [math]::Max(0, $backupMinutes)
    $backupCount = [math]::Max(1, [math]::Min(300, $backupCount))

    $backupDirectory = Join-Path ([string]$Profile.dataRoot) "backups\period"
    $backupFiles = @()
    if (Test-Path -LiteralPath $backupDirectory -PathType Container) {
        $backupFiles = @(Get-ChildItem -LiteralPath $backupDirectory -File -Filter "*.zip" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)
    }
    $latest = $backupFiles | Select-Object -First 1
    [long]$totalBytes = 0
    foreach ($file in $backupFiles) { $totalBytes += [long]$file.Length }
    $nextBackupAt = $null
    if ($backupMinutes -gt 0 -and $latest) {
        $nextBackupAt = $latest.LastWriteTime.AddMinutes($backupMinutes).ToString("o")
    }

    return [ordered]@{
        ok = $true
        serverId = [string]$Profile.id
        iniPath = $iniPath
        autoSaveEnabled = [bool]($saveMinutes -gt 0)
        saveIntervalMinutes = if ($saveMinutes -gt 0) { $saveMinutes } else { 10 }
        autoBackupEnabled = [bool]($backupMinutes -gt 0)
        backupIntervalMinutes = if ($backupMinutes -gt 0) { $backupMinutes } else { 60 }
        backupCount = $backupCount
        backupDirectory = $backupDirectory
        backupDirectoryExists = [bool](Test-Path -LiteralPath $backupDirectory -PathType Container)
        backupFileCount = $backupFiles.Count
        backupTotalBytes = $totalBytes
        latestBackupAt = if ($latest) { $latest.LastWriteTime.ToString("o") } else { $null }
        latestBackupBytes = if ($latest) { [long]$latest.Length } else { 0L }
        latestBackupName = if ($latest) { [string]$latest.Name } else { $null }
        nextBackupAt = $nextBackupAt
    }
}

function Set-PZSaveBackupSettings {
    param(
        $Profile,
        [bool]$AutoSaveEnabled,
        [int]$SaveIntervalMinutes,
        [bool]$AutoBackupEnabled,
        [int]$BackupIntervalMinutes,
        [int]$BackupCount,
        [string]$Remote = "local"
    )
    if ($SaveIntervalMinutes -lt 1 -or $SaveIntervalMinutes -gt 1440) {
        throw "自动保存间隔必须为 1 至 1440 分钟。"
    }
    if ($BackupIntervalMinutes -lt 15 -or $BackupIntervalMinutes -gt 1500) {
        throw "自动备份间隔必须为 15 至 1500 分钟。"
    }
    if ($BackupCount -lt 1 -or $BackupCount -gt 300) {
        throw "备份保留数量必须为 1 至 300 份。"
    }

    $saveValue = if ($AutoSaveEnabled) { $SaveIntervalMinutes } else { 0 }
    $backupValue = if ($AutoBackupEnabled) { $BackupIntervalMinutes } else { 0 }
    $iniPath = Join-Path (Join-Path ([string]$Profile.dataRoot) "Server") "$([string]$Profile.serverName).ini"
    $settings = [ordered]@{
        SaveWorldEveryMinutes = $saveValue
        BackupsPeriod = $backupValue
        BackupsCount = $BackupCount
    }
    $writeResult = Set-PZIniSettings -Path $iniPath -Settings $settings
    if (-not $writeResult.updated) { throw "找不到服务器 INI：$iniPath" }

    $requestIds = @()
    $runtimeWarning = $null
    $state = Get-ServerState -Profile $Profile
    if ($state.alive -and $state.writable) {
        $logCursor = 0L
        if ($Profile.consoleLog -and (Test-Path -LiteralPath ([string]$Profile.consoleLog))) {
            $logCursor = (Get-Item -LiteralPath ([string]$Profile.consoleLog)).Length
        }
        try {
            foreach ($entry in $settings.GetEnumerator()) {
                $command = "changeoption $($entry.Key) `"$($entry.Value)`""
                $queued = Queue-Command -Profile $Profile -Command $command -RequireReceipt:$true
                $requestId = [string]$queued.id
                $requestIds += $requestId
                $commandRequests[$requestId] = [pscustomobject]@{
                    serverId = [string]$Profile.id
                    action = "save-backup-settings"
                    command = $command
                    queuedAt = [string]$queued.createdAt
                    logCursor = $logCursor
                }
            }
        }
        catch { $runtimeWarning = $_.Exception.Message }
    }
    elseif ($state.alive) {
        $runtimeWarning = "服务器正在运行，但受控命令通道不可写；INI 已保存，将在下次启动时完整生效。"
    }

    $runtimeMessage = if ($requestIds.Count -gt 0 -and -not $runtimeWarning) {
        "INI 已保存，在线热更新命令已提交。"
    }
    elseif ($runtimeWarning) { "INI 已保存。$runtimeWarning" }
    else { "INI 已保存，将在下次启动时生效。" }
    Add-Audit -Remote $Remote -Action "save-backup-settings" -Detail "server=$($Profile.id) autoSave=$AutoSaveEnabled saveMinutes=$saveValue autoBackup=$AutoBackupEnabled backupMinutes=$backupValue backupCount=$BackupCount requests=$($requestIds.Count)" -Result $(if ($runtimeWarning) { "warning" } else { "ok" })
    [void](Add-ExecutionHistoryRecord -ServerId ([string]$Profile.id) -Category "command" -Action "save-backup-settings" -Source "web" `
        -Summary "更新自动保存与备份计划" -Status $(if ($runtimeWarning) { "warning" } else { "success" }) `
        -Message $runtimeMessage -RequestIds $requestIds -Detail "SaveWorldEveryMinutes=$saveValue`nBackupsPeriod=$backupValue`nBackupsCount=$BackupCount")

    return (@{ message = $runtimeMessage; runtimeRequestIds = $requestIds; runtimeWarning = $runtimeWarning } + (Get-PZSaveBackupPayload -Profile $Profile))
}

function Get-PZProgramUpdateStatus {
    param($Profile, [switch]$QueryRemote)
    $steamCmdPath = Find-SteamCmdPath -Profile $Profile
    $local = Get-PZLocalBuildInfo -Profile $Profile -SteamCmdPath $steamCmdPath
    $remoteBuildId = $null
    $queryDetail = ""
    if ($QueryRemote) {
        if (-not $steamCmdPath) { throw "找不到 steamcmd.exe。请先安装 SteamCMD，或将其放到任一磁盘的 SteamCMD 目录。" }
        $remote = Invoke-SteamCmdMetadataQuery -SteamCmdPath $steamCmdPath
        $remoteBuildId = [string]$remote.buildId
        $queryDetail = [string]$remote.detail
    }
    $known = -not [string]::IsNullOrWhiteSpace([string]$local.buildId) -and -not [string]::IsNullOrWhiteSpace($remoteBuildId)
    return [ordered]@{
        ok = $true
        serverId = [string]$Profile.id
        appId = "380870"
        branch = "public"
        runtimeRoot = [string]$Profile.runtimeRoot
        steamCmdAvailable = [bool]$steamCmdPath
        steamCmdPath = $steamCmdPath
        localBuildId = $local.buildId
        localVersion = $local.version
        manifestPath = $local.manifestPath
        expectedManifestPath = $local.expectedManifestPath
        installMode = $local.installMode
        remoteBuildId = $remoteBuildId
        comparisonKnown = [bool]$known
        updateAvailable = [bool]($known -and [string]$local.buildId -cne $remoteBuildId)
        current = [bool]($known -and [string]$local.buildId -ceq $remoteBuildId)
        checkedAt = if ($QueryRemote) { (Get-Date).ToString("o") } else { $null }
        detail = $queryDetail
    }
}

function Get-MaintenanceSchedulePayload {
    param($Profile)
    $schedule = Get-MaintenanceSchedule -ServerId ([string]$Profile.id)
    $running = $false
    if ($schedule.lastRequestId) { $running = $maintenanceChecks.ContainsKey([string]$schedule.lastRequestId) }
    return [ordered]@{
        ok = $true
        serverId = [string]$Profile.id
        enabled = [bool]$schedule.enabled
        intervalHours = [int]$schedule.intervalHours
        autoRestartOnUpdate = [bool]$schedule.autoRestartOnUpdate
        autoRestartWarningSeconds = 60
        restartStabilizationSeconds = [int]$schedule.restartStabilizationSeconds
        nextRunAt = $schedule.nextRunAt
        running = [bool]$running
        lastRunAt = $schedule.lastRunAt
        lastStatus = [string]$schedule.lastStatus
        lastResultCode = $schedule.lastResultCode
        lastMessage = $schedule.lastMessage
        lastRequestId = $schedule.lastRequestId
        updateNotificationPending = [bool]$schedule.updateNotificationPending
        lastNotificationAt = $schedule.lastNotificationAt
        lastAutoRestartAt = $schedule.lastAutoRestartAt
        lastAutoRestartOperationId = $schedule.lastAutoRestartOperationId
    }
}

function Start-ScheduledModCheck {
    param($Profile, [switch]$Manual)
    $serverId = [string]$Profile.id
    $schedule = Get-MaintenanceSchedule -ServerId $serverId
    if ($schedule.lastRequestId -and $maintenanceChecks.ContainsKey([string]$schedule.lastRequestId)) {
        throw "该服务器的 Mod 更新检查仍在进行中。"
    }
    $now = Get-Date
    $schedule.lastRunAt = $now.ToString("o")
    $schedule.nextRunAt = if ($schedule.enabled) { $now.AddHours([int]$schedule.intervalHours).ToString("o") } else { $null }
    $state = Get-ServerState -Profile $Profile
    if (-not $state.alive -or -not $state.writable) {
        $schedule.lastStatus = "skipped"
        $schedule.lastResultCode = "server-unavailable"
        $schedule.lastMessage = if (-not $state.alive) { "服务器已停止，本次检查已跳过。" } else { "受控命令通道不可写，本次检查已跳过：$($state.note)" }
        $schedule.lastRequestId = $null
        Save-MaintenanceSchedules
        Add-Audit -Remote "local" -Action "scheduled-mod-check" -Detail "server=$serverId $($schedule.lastMessage)" -Result "skipped"
        [void](Add-ExecutionHistoryRecord -ServerId $serverId -Category "update" -Action "check-mod-updates" `
            -Source $(if ($Manual) { "web" } else { "scheduled" }) -Summary "检查 Mod 更新" -Status "warning" `
            -Message ([string]$schedule.lastMessage))
        return Get-MaintenanceSchedulePayload -Profile $Profile
    }

    $logCursor = 0L
    if ($Profile.consoleLog -and (Test-Path -LiteralPath ([string]$Profile.consoleLog))) {
        $logCursor = (Get-Item -LiteralPath ([string]$Profile.consoleLog)).Length
    }
    $queued = Queue-Command -Profile $Profile -Command "checkModsNeedUpdate" -RequireReceipt:$true
    $requestId = [string]$queued.id
    $tracked = [pscustomobject]@{
        serverId = $serverId
        action = "check-mod-updates"
        command = "checkModsNeedUpdate"
        queuedAt = [string]$queued.createdAt
        logCursor = $logCursor
    }
    $commandRequests[$requestId] = $tracked
    $maintenanceChecks[$requestId] = [pscustomobject]@{ serverId = $serverId; startedAt = $now; manual = [bool]$Manual }
    $schedule.lastStatus = "checking"
    $schedule.lastResultCode = "mods-checking"
    $schedule.lastMessage = "已提交 Mod 更新检查，正在等待服务器返回最终结果。"
    $schedule.lastRequestId = $requestId
    Save-MaintenanceSchedules
    Add-Audit -Remote "local" -Action $(if ($Manual) { "manual-mod-check" } else { "scheduled-mod-check" }) -Detail "server=$serverId request=$requestId" -Result "queued"
    [void](Add-ExecutionHistoryRecord -ServerId $serverId -Category "update" -Action "check-mod-updates" `
        -Source $(if ($Manual) { "web" } else { "scheduled" }) -Summary "检查 Mod 更新" -Status "queued" `
        -Message ([string]$schedule.lastMessage) -RequestIds @($requestId))
    return Get-MaintenanceSchedulePayload -Profile $Profile
}

function Start-AutomaticModRestart {
    param($Profile, $Schedule)
    $warningSeconds = 60
    $restartStabilizationSeconds = [int]$Schedule.restartStabilizationSeconds
    $serverState = Get-ServerState -Profile $Profile
    if (-not $serverState.canRestart) { throw "服务器尚未由面板受控启动，当前不能执行安全重启。" }
    if ([bool]$serverState.adminSetupRequired) {
        throw "游戏账号数据库已缺失，不能执行安全重启。请先停止服务器，再点击启动按钮设置一次游戏内置 admin 密码。"
    }
    $operationId = Start-LifecycleOperation -Profile $Profile -Action "restart" -WarningSeconds $warningSeconds -RestartStabilizationSeconds $restartStabilizationSeconds -Trigger "mod-update"
    $queuedAt = (Get-Date).ToString("o")
    $Schedule.lastAutoRestartAt = $queuedAt
    $Schedule.lastAutoRestartOperationId = $operationId
    $Schedule.lastNotificationAt = $queuedAt
    $Schedule.updateNotificationPending = $true
    $script:statusCache = $null
    $script:statusCacheAt = [datetime]::MinValue
    Add-Audit -Remote "local" -Action "scheduled-mod-restart" -Detail "server=$($Profile.id) warningSeconds=$warningSeconds stabilizationSeconds=$restartStabilizationSeconds operation=$operationId trigger=mod-update" -Result "queued"
    [void](Add-ExecutionHistoryRecord -ServerId ([string]$Profile.id) -Category "lifecycle" -Action "restart" -Source "scheduled" `
        -Summary "Mod 更新自动安全重启（通知 60 秒，停服缓冲 $restartStabilizationSeconds 秒）" -Status "queued" `
        -Message "检测到 Mod 更新，正在发送原生广播和 PZWebNotices 弹窗；60 秒后将保存并退出，旧 Java 完全结束后再等待 $restartStabilizationSeconds 秒启动。" -OperationId $operationId)
    return $operationId
}

function Complete-ScheduledModCheck {
    param([string]$RequestId)
    if (-not $maintenanceChecks.ContainsKey($RequestId)) { return }
    $check = $maintenanceChecks[$RequestId]
    $profile = Get-ServerProfile -Id ([string]$check.serverId)
    $schedule = Get-MaintenanceSchedule -ServerId ([string]$profile.id)
    try { $result = Get-CommandResultPayload -Profile $profile -Id $RequestId }
    catch {
        $schedule.lastStatus = "failed"
        $schedule.lastResultCode = "check-failed"
        $schedule.lastMessage = "读取 Mod 检查结果失败：$($_.Exception.Message)"
        $maintenanceChecks.Remove($RequestId)
        Save-MaintenanceSchedules
        return
    }
    if (-not $result.done) { return }

    $schedule.lastResultCode = $result.resultCode
    switch ([string]$result.resultCode) {
        "mods-current" {
            $schedule.lastStatus = "current"
            $schedule.lastMessage = "检查完成：当前服务器使用的 Mod 已是最新版本，无需更新。"
            $schedule.updateNotificationPending = $false
        }
        "mods-update-required" {
            $schedule.lastStatus = "update-required"
            $schedule.lastMessage = "检测到 Mod 有新版本，请安排安全重启。"
            if (-not $schedule.updateNotificationPending) {
                if ([bool]$schedule.autoRestartOnUpdate) {
                    try {
                        $operationId = Start-AutomaticModRestart -Profile $profile -Schedule $schedule
                        $schedule.lastStatus = "auto-restart-queued"
                        $schedule.lastMessage = "检测到 Mod 有新版本，已提交 60 秒双通道通知的自动安全重启；旧 Java 停止后将缓冲 $([int]$schedule.restartStabilizationSeconds) 秒再启动。"
                    }
                    catch {
                        $schedule.lastStatus = "auto-restart-failed"
                        $schedule.lastMessage = "检测到 Mod 有新版本，但自动安全重启未能启动：$($_.Exception.Message)"
                        $schedule.lastAutoRestartAt = (Get-Date).ToString("o")
                        $schedule.lastAutoRestartOperationId = $null
                        $schedule.updateNotificationPending = $false
                        Add-Audit -Remote "local" -Action "scheduled-mod-restart" -Detail "server=$($profile.id) $($_.Exception.Message)" -Result "failed"
                        [void](Add-ExecutionHistoryRecord -ServerId ([string]$profile.id) -Category "lifecycle" -Action "restart" -Source "scheduled" `
                            -Summary "Mod 更新自动安全重启" -Status "failed" -Message ([string]$schedule.lastMessage))
                    }
                }
                else {
                    $notification = Send-MaintenanceAnnouncement -Profile $profile -Title "Mod 更新维护" -Message "检测到服务器 Mod 有新版本，请准备维护重启并尽快前往安全区域。"
                    if ($notification.delivered) {
                        $schedule.updateNotificationPending = $true
                        $schedule.lastNotificationAt = (Get-Date).ToString("o")
                        if ($notification.warnings.Count -gt 0) { $schedule.lastMessage += " " + ($notification.warnings -join "；") }
                        [void](Add-ExecutionHistoryRecord -ServerId ([string]$profile.id) -Category "broadcast" -Action "mod-update-notice" `
                            -Source "scheduled" -Summary "发现 Mod 更新后的维护通知" -Status $(if ($notification.warnings.Count) { "warning" } else { "queued" }) `
                            -Message $(if ($notification.warnings.Count) { $notification.warnings -join "；" } else { "原生广播和 Mod 弹窗已提交。" }) `
                            -RequestIds @($notification.requestIds) -NoticeId ([string]$notification.noticeId) -Detail "检测到服务器 Mod 有新版本，请准备维护重启并尽快前往安全区域。")
                    }
                    else {
                        $schedule.lastStatus = "notification-failed"
                        $schedule.lastMessage += " 通知未能发送：" + ($notification.warnings -join "；")
                        [void](Add-ExecutionHistoryRecord -ServerId ([string]$profile.id) -Category "broadcast" -Action "mod-update-notice" `
                            -Source "scheduled" -Summary "发现 Mod 更新后的维护通知" -Status "failed" `
                            -Message ($notification.warnings -join "；"))
                    }
                }
            }
        }
        default {
            $schedule.lastStatus = if ($result.status -eq "failed") { "failed" } else { "no-result" }
            $schedule.lastResultCode = if ($result.status -eq "failed") { "check-failed" } else { "no-final-result" }
            $schedule.lastMessage = if ($result.status -eq "failed") { "Mod 更新检查命令执行失败。" } else { "服务器未在等待时间内返回明确的 Mod 更新结果，请查看命令结果或日志。" }
        }
    }
    $maintenanceChecks.Remove($RequestId)
    Save-MaintenanceSchedules
    Add-Audit -Remote "local" -Action "mod-check-result" -Detail "server=$($profile.id) result=$($schedule.lastResultCode) message=$($schedule.lastMessage)" -Result $schedule.lastStatus
}

function Invoke-MaintenanceSchedulerTick {
    $now = Get-Date
    if (($now - $maintenanceLastTick).TotalMilliseconds -lt 750) { return }
    $script:maintenanceLastTick = $now
    foreach ($requestId in @($maintenanceChecks.Keys)) { Complete-ScheduledModCheck -RequestId $requestId }
    foreach ($profile in @($serverProfiles)) {
        $schedule = Get-MaintenanceSchedule -ServerId ([string]$profile.id)
        if (-not $schedule.enabled -or ($schedule.lastRequestId -and $maintenanceChecks.ContainsKey([string]$schedule.lastRequestId))) { continue }
        $due = $false
        if ([string]::IsNullOrWhiteSpace([string]$schedule.nextRunAt)) { $due = $true }
        else {
            try { $due = $now -ge [datetime]$schedule.nextRunAt }
            catch { $due = $true }
        }
        if ($due) {
            try { [void](Start-ScheduledModCheck -Profile $profile) }
            catch {
                $schedule.lastStatus = "failed"
                $schedule.lastResultCode = "queue-failed"
                $schedule.lastMessage = "自动检查提交失败：$($_.Exception.Message)"
                $schedule.nextRunAt = $now.AddHours([int]$schedule.intervalHours).ToString("o")
                Save-MaintenanceSchedules
            }
        }
    }
}

function Invoke-BroadcastSchedule {
    param($Schedule)
    $profile = Get-ServerProfile -Id ([string]$Schedule.serverId)
    $now = Get-Date
    $Schedule.lastRunAt = $now.ToString("o")
    $Schedule.nextRunAt = $now.AddMinutes([int]$Schedule.intervalMinutes).ToString("o")
    $requestIds = @()
    $noticeId = ""
    $warnings = @()
    $channels = @()
    $logCursor = 0L
    if ($profile.consoleLog -and (Test-Path -LiteralPath ([string]$profile.consoleLog))) {
        $logCursor = (Get-Item -LiteralPath ([string]$profile.consoleLog)).Length
    }

    if ([string]$Schedule.channel -in @("native", "both")) {
        try {
            foreach ($command in @(Get-BroadcastCommands -Message ([string]$Schedule.message))) {
                $queued = Queue-Command -Profile $profile -Command $command -RequireReceipt:$true
                $requestIds += [string]$queued.id
                $commandRequests[[string]$queued.id] = [pscustomobject]@{
                    serverId = [string]$profile.id; action = "broadcast"; command = [string]$command
                    queuedAt = [string]$queued.createdAt; logCursor = $logCursor
                }
            }
            $channels += "原生全服广播"
        }
        catch { $warnings += "原生广播失败：$($_.Exception.Message)" }
    }

    if ([string]$Schedule.channel -in @("popup", "both")) {
        try {
            $state = Get-ServerState -Profile $profile
            if (-not $state.alive) { throw "服务器当前未运行。" }
            $heartbeat = Get-NoticeHeartbeat -Profile $profile
            if (-not $heartbeat.usable -or -not $heartbeat.v3Compatible) { throw "PZWebNotices 通道当前不可用或版本低于 0.2.3。" }
            $noticeId = "notice-" + [guid]::NewGuid().ToString("N")
            $expected = if ($state.onlineKnown) { [int]$state.onlineCount } else { 0 }
            Add-NoticeQueueEntry -Profile $profile -Id $noticeId -TargetType "all" -TargetUsername "" `
                -Style ([string]$Schedule.style) -Duration ([int]$Schedule.duration) -TitleSize "medium" -BodySize "small" `
                -AccentColor $(switch ([string]$Schedule.style) { "success" { "#4FC38A" } "warning" { "#E3A846" } "danger" { "#E56565" } default { "#62A7DF" } }) `
                -TextColor "#E1E6E9" -Title ([string]$Schedule.title) -Message ([string]$Schedule.message) -ExpectedClients $expected
            $channels += "Mod 弹窗"
        }
        catch { $warnings += "弹窗广播失败：$($_.Exception.Message)" }
    }

    if ($channels.Count -eq 0) {
        $Schedule.lastStatus = "failed"
        $Schedule.lastMessage = $warnings -join "；"
        [void](Add-ExecutionHistoryRecord -ServerId ([string]$profile.id) -Category "broadcast" -Action "scheduled-broadcast" -Source "scheduled" `
            -Summary ([string]$Schedule.name) -Status "failed" -Message ([string]$Schedule.lastMessage) -Detail ([string]$Schedule.message))
    }
    else {
        $Schedule.lastStatus = if ($warnings.Count) { "warning" } else { "queued" }
        $Schedule.lastMessage = "已提交：$($channels -join ' + ')" + $(if ($warnings.Count) { "；" + ($warnings -join "；") } else { "" })
        [void](Add-ExecutionHistoryRecord -ServerId ([string]$profile.id) -Category "broadcast" -Action "scheduled-broadcast" -Source "scheduled" `
            -Summary ([string]$Schedule.name) -Status $(if ($warnings.Count) { "warning" } else { "queued" }) -Message ([string]$Schedule.lastMessage) `
            -RequestIds $requestIds -NoticeId $noticeId -Detail ([string]$Schedule.message))
    }
    $Schedule.updatedAt = $now.ToString("o")
    Save-BroadcastSchedules
    Add-Audit -Remote "local" -Action "scheduled-broadcast" -Detail "server=$($profile.id) schedule=$($Schedule.id) channels=$($channels -join ',')" -Result ([string]$Schedule.lastStatus)
}

function Invoke-BroadcastSchedulerTick {
    $now = Get-Date
    foreach ($schedule in @($broadcastSchedules)) {
        if (-not [bool]$schedule.enabled) { continue }
        $serverId = [string]$schedule.serverId
        $due = $false
        if ([string]::IsNullOrWhiteSpace([string]$schedule.nextRunAt)) { $due = $true }
        else {
            try { $due = $now -ge [datetime]$schedule.nextRunAt }
            catch { $due = $true }
        }
        if ($due) {
            $lastDispatch = if ($broadcastLastDispatchAt.ContainsKey($serverId)) { [datetime]$broadcastLastDispatchAt[$serverId] } else { [datetime]::MinValue }
            if (($now - $lastDispatch).TotalSeconds -lt $broadcastDispatchSpacingSeconds) { continue }
            try { Invoke-BroadcastSchedule -Schedule $schedule }
            catch {
                $schedule.lastRunAt = $now.ToString("o")
                $schedule.nextRunAt = $now.AddMinutes([int]$schedule.intervalMinutes).ToString("o")
                $schedule.lastStatus = "failed"
                $schedule.lastMessage = $_.Exception.Message
                Save-BroadcastSchedules
                [void](Add-ExecutionHistoryRecord -ServerId ([string]$schedule.serverId) -Category "broadcast" -Action "scheduled-broadcast" -Source "scheduled" -Summary ([string]$schedule.name) -Status "failed" -Message $_.Exception.Message)
            }
            finally { $broadcastLastDispatchAt[$serverId] = Get-Date }
        }
    }
}

function Invoke-ExecutionHistoryTick {
    $now = Get-Date
    if (($now - $executionHistoryLastTick).TotalSeconds -lt 1) { return }
    $script:executionHistoryLastTick = $now
    $changed = $false
    foreach ($record in @($executionHistory | Where-Object {
        ([string]$_.status -in @("queued", "running") -or ([string]$_.status -eq "warning" -and [string]::IsNullOrWhiteSpace([string]$_.resultCode))) -and
        (@($_.requestIds).Count -gt 0 -or @($_.auxiliaryRequestIds).Count -gt 0 -or -not [string]::IsNullOrWhiteSpace([string]$_.noticeId) -or
        -not [string]::IsNullOrWhiteSpace([string]$_.operationId) -or [string]$_.action -eq "start")
    })) {
        $profile = $serverProfiles | Where-Object { [string]$_.id -ceq [string]$record.serverId } | Select-Object -First 1
        if (-not $profile) { continue }
        $parts = @()
        $settled = $true
        $failed = $false
        $resultCode = $null
        $operationDetail = $null
        $preserveWarning = [string]$record.status -eq "warning"

        if ([string]$record.action -eq "start" -and @($record.requestIds).Count -eq 0 -and
            [string]::IsNullOrWhiteSpace([string]$record.noticeId) -and [string]::IsNullOrWhiteSpace([string]$record.operationId)) {
            $state = Get-ServerState -Profile $profile
            if ($state.alive -and [string]$state.status -eq "running") { $parts += "服务器已进入运行状态。" }
            elseif (($now - [datetime]$record.createdAt).TotalMinutes -lt 5) { $settled = $false; $parts += "正在等待服务器进入运行状态。" }
            else { $failed = $true; $parts += "启动脚本已运行，但 5 分钟内未检测到服务器进入运行状态。" }
        }

        $primaryResults = @()
        if (@($record.requestIds).Count -gt 0) {
            try { $primaryResults = @((Get-CommandResultsPayload -Profile $profile -Ids @($record.requestIds)).results) }
            catch { $settled = $false; $parts += $_.Exception.Message }
        }
        if ([string]$record.action -eq 'additem' -and $primaryResults.Count -gt 0) {
            $confirmed = @($primaryResults | Where-Object { [string]$_.gameStatus -eq 'success' })
            $explicitFailures = @($primaryResults | Where-Object { [string]$_.gameStatus -eq 'failed' -or [string]$_.status -eq 'failed' })
            $unconfirmed = @($primaryResults | Where-Object { [string]$_.gameStatus -eq 'unconfirmed' })
            $delivered = @($primaryResults | Where-Object { [string]$_.gameStatus -eq 'pending' })
            $queued = @($primaryResults | Where-Object { [string]$_.gameStatus -eq 'queued' })
            if (@($primaryResults | Where-Object { -not [bool]$_.done }).Count -gt 0) { $settled = $false }
            if ($explicitFailures.Count -gt 0) { $failed = $true }
            if ($unconfirmed.Count -gt 0) { $preserveWarning = $true; $resultCode = 'item-result-unconfirmed' }
            $parts += "物品发放进度：游戏确认成功 $($confirmed.Count)/$($primaryResults.Count)，明确失败 $($explicitFailures.Count)，待确认 $($unconfirmed.Count + $delivered.Count)，排队 $($queued.Count)。"
            foreach ($failureResult in @($explicitFailures | Select-Object -First 20)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$failureResult.resultMessage)) { $parts += [string]$failureResult.resultMessage }
            }
            if ($unconfirmed.Count -gt 0) { $parts += "$($unconfirmed.Count) 条命令已送达但未捕获明确游戏结果，为避免重复发放，请先核对后再重试。" }
        }
        else {
            foreach ($result in $primaryResults) {
                if (-not $result.done) { $settled = $false }
                if ([string]$result.status -eq "failed") { $failed = $true }
                if ($result.resultCode) { $resultCode = [string]$result.resultCode }
                if ($result.resultMessage) { $parts += [string]$result.resultMessage }
                elseif ($result.output.Count) { $parts += (@($result.output) -join "`n") }
                elseif ($result.receipt) { $parts += "命令已写入服务器控制台。" }
            }
        }

        foreach ($requestId in @($record.auxiliaryRequestIds)) {
            if ([string]::IsNullOrWhiteSpace([string]$requestId)) { continue }
            try {
                $result = Get-CommandResultPayload -Profile $profile -Id ([string]$requestId)
                if (-not $result.done) { $settled = $false }
                if ([string]$result.status -eq "failed") {
                    $preserveWarning = $true
                    $broadcastError = if ($result.receipt -and -not [string]::IsNullOrWhiteSpace([string]$result.receipt.error)) {
                        [string]$result.receipt.error
                    } elseif (-not [string]::IsNullOrWhiteSpace([string]$result.resultMessage)) {
                        [string]$result.resultMessage
                    } else { "未知错误" }
                    $parts += "附加文字广播失败：$broadcastError"
                }
                elseif ($result.receipt) { $parts += "附加文字广播已写入服务器控制台。" }
            }
            catch { $settled = $false; $parts += $_.Exception.Message }
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$record.noticeId)) {
            try {
                $notice = Get-NoticeReceiptPayload -Profile $profile -Id ([string]$record.noticeId)
                if ([string]$notice.status -eq "rejected") {
                    if ([string]$record.action -eq "additem") { $preserveWarning = $true }
                    else { $failed = $true }
                    $parts += "Mod 弹窗被拒绝：$($notice.error)"
                }
                elseif ([string]$notice.status -in @("broadcast", "directed")) {
                    $expectedClients = [int]$notice.expectedClients
                    $acknowledgedClients = [int]$notice.acknowledgedClients
                    if ($expectedClients -eq 0 -or $acknowledgedClients -ge $expectedClients) {
                        $parts += "Mod 弹窗已由服务端发送，客户端确认 $acknowledgedClients/$expectedClients。"
                    }
                    elseif (($now - [datetime]$record.createdAt).TotalSeconds -lt 60) { $settled = $false }
                    else {
                        $preserveWarning = $true
                        $parts += "Mod 弹窗已由服务端发送，但 60 秒内客户端只确认 $acknowledgedClients/$expectedClients。"
                    }
                }
                elseif (($now - [datetime]$record.createdAt).TotalSeconds -lt 60) { $settled = $false }
                else { $preserveWarning = $true; $parts += "Mod 弹窗已提交，但在 60 秒内没有返回送达回执。" }
            }
            catch { $settled = $false; $parts += $_.Exception.Message }
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$record.operationId)) {
            try {
                $payload = Get-LifecycleOperationPayload -Profile $profile -Id ([string]$record.operationId)
                if (-not $payload.available -or [string]$payload.operation.status -in @("queued", "running")) { $settled = $false }
                elseif ([string]$payload.operation.status -eq "failed") {
                    $failed = $true
                    $parts += [string]$payload.operation.message
                    if (-not [string]::IsNullOrWhiteSpace([string]$payload.operation.error)) { $parts += [string]$payload.operation.error }
                }
                else { $parts += [string]$payload.operation.message }
                if (-not [string]::IsNullOrWhiteSpace([string]$payload.operation.detail)) {
                    $operationDetail = [string]$payload.operation.detail
                }
            }
            catch { $settled = $false; $parts += $_.Exception.Message }
        }

        if ($settled) {
            $message = @($parts | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique) -join "`n"
            if ([string]::IsNullOrWhiteSpace($message)) { $message = if ($failed) { "执行失败。" } else { "执行完成，服务器通道已返回结果。" } }
            $finalResultCode = if (-not [string]::IsNullOrWhiteSpace([string]$resultCode)) { $resultCode } elseif ($failed) { "failed" } elseif ($preserveWarning) { "completed-with-warning" } else { "completed" }
            Set-ExecutionHistoryResult -Record $record -Status $(if ($failed) { "failed" } elseif ($preserveWarning) { "warning" } else { "success" }) -ResultCode $finalResultCode -Message $message -Detail $operationDetail
            $changed = $true
        }
        elseif ([string]$record.status -eq "queued") { $record.status = "running"; $record.updatedAt = $now.ToString("o"); $changed = $true }
    }
    if ($changed) { Save-ExecutionHistory }
}

function Get-LifecycleOperationPayload {
    param($Profile, [string]$Id)
    if ($Id -and $Id -notmatch '^[a-f0-9]{32}$') { throw "生命周期操作 ID 无效。" }
    $paths = Get-ManagedProfilePaths -Id ([string]$Profile.id)
    if (-not (Test-Path -LiteralPath $paths.operationPath)) {
        return [ordered]@{ ok = $true; serverId = [string]$Profile.id; available = $false; operation = $null }
    }
    try { $operation = Get-Content -LiteralPath $paths.operationPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw "生命周期状态文件暂时无法读取，请稍后重试。" }
    if ($Id -and [string]$operation.id -cne $Id) { throw "该生命周期操作已被更新的操作替代。" }
    return [ordered]@{ ok = $true; serverId = [string]$Profile.id; available = $true; operation = $operation }
}

function Get-ActiveLifecycleOperation {
    param($Profile)
    $paths = Get-ManagedProfilePaths -Id ([string]$Profile.id)
    if (-not (Test-Path -LiteralPath $paths.operationPath)) { return $null }
    try {
        $operation = Get-Content -LiteralPath $paths.operationPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $isRecent = $operation.updatedAt -and ((Get-Date) - [datetime]$operation.updatedAt).TotalHours -lt 2
        if ($isRecent -and [string]$operation.status -in @("queued", "running")) { return $operation }
    }
    catch { }
    return $null
}

function Start-LifecycleOperation {
    param(
        $Profile,
        [string]$Action,
        [int]$WarningSeconds = 60,
        [ValidateRange(10, 600)][int]$RestartStabilizationSeconds = 60,
        [ValidateSet("manual", "mod-update")][string]$Trigger = "manual",
        [string]$SteamCmdPath = "",
        [string]$RemoteBuildId = ""
    )
    $paths = Get-ManagedProfilePaths -Id ([string]$Profile.id)
    $current = Get-ActiveLifecycleOperation -Profile $Profile
    if ($current) { throw "已有服务器生命周期操作正在执行：$($current.message)" }
    $operationId = [guid]::NewGuid().ToString("N")
    $now = (Get-Date).ToString("o")
    $operation = [ordered]@{
        id = $operationId
        action = $Action
        trigger = $Trigger
        serverId = [string]$Profile.id
        status = "queued"
        stage = "queued"
        message = "操作已提交，等待后台执行器启动。"
        startedAt = $now
        updatedAt = $now
        oldJavaPid = $null
        newJavaPid = $null
        warningSeconds = if ($Action -in @("restart", "update")) { $WarningSeconds } else { 0 }
        countdownUntil = $null
        restartStabilizationSeconds = if ($Action -in @("restart", "update")) { $RestartStabilizationSeconds } else { 0 }
        stabilizationUntil = $null
        warnings = @()
        error = $null
    }
    [IO.File]::WriteAllText($paths.operationPath, ($operation | ConvertTo-Json -Depth 4), $utf8)
    try {
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$managedLifecyclePath`" -Action $Action -OperationId $operationId -ProfilePath `"$($paths.profilePath)`" -WarningSeconds $WarningSeconds -RestartStabilizationSeconds $RestartStabilizationSeconds -Trigger $Trigger"
        if ($Action -eq "update") {
            $layout = Get-PZInstallLayout -Profile $Profile -SteamCmdPath $SteamCmdPath
            $arguments += " -SteamCmdPath `"$SteamCmdPath`" -InstallDirectory `"$([string]$layout.runtimeRoot)`" -InstallMode `"$([string]$layout.installMode)`" -ManifestPath `"$([string]$layout.manifestPath)`" -RemoteBuildId `"$RemoteBuildId`""
        }
        Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -WindowStyle Hidden | Out-Null
    }
    catch {
        $operation.status = "failed"
        $operation.stage = "failed"
        $operation.message = "后台执行器未能启动。"
        $operation.updatedAt = (Get-Date).ToString("o")
        $operation.error = $_.Exception.Message
        [IO.File]::WriteAllText($paths.operationPath, ($operation | ConvertTo-Json -Depth 4), $utf8)
        throw
    }
    return $operationId
}

try {
    $startupDiscovered = @(Find-RunningPZServers)
    if ($startupDiscovered.Count -gt 0) {
        Save-ServerProfiles -Profiles (@($serverProfiles) + $startupDiscovered) -DefaultServer ([string]$profileConfig.defaultServer)
        Add-Audit -Remote "local" -Action "profile-auto-scan" -Detail "added=$($startupDiscovered.Count)" -Result "ok"
    }
}
catch {
    Add-Audit -Remote "local" -Action "profile-auto-scan" -Detail $_.Exception.Message -Result "failed"
}

foreach ($managedProfile in @($serverProfiles | Where-Object { Test-IsManagedProfile -Profile $_ })) {
    try { Ensure-ManagedProfile -Profile $managedProfile }
    catch { Add-Audit -Remote "local" -Action "managed-repair" -Detail "server=$($managedProfile.id) $($_.Exception.Message)" -Result "failed" }
}

New-Item -ItemType Directory -Path $managedRoot, $itemIndexRoot -Force | Out-Null
if (-not (Test-Path -LiteralPath $managedHostPath)) { throw "缺少托管主机脚本：$managedHostPath" }
if (-not (Test-Path -LiteralPath $managedLifecyclePath)) { throw "缺少托管生命周期脚本：$managedLifecyclePath" }
if (-not (Test-Path -LiteralPath $itemIndexBuilderPath)) { throw "缺少物品索引器：$itemIndexBuilderPath" }
if (-not (Test-Path -LiteralPath $aiBridgeModulePath)) { throw "缺少内置 AI Bridge：$aiBridgeModulePath" }
. $aiBridgeModulePath
Initialize-AIBridge
$maintenanceSchedules = Read-MaintenanceSchedules
$aiOperationPolicies = @(Read-AIOperationPolicies)
$broadcastSchedules = @(Read-BroadcastSchedules)
$executionHistory = @(Read-ExecutionHistory)
foreach ($schedule in @($maintenanceSchedules.Values)) {
    if ([string]$schedule.lastStatus -eq "checking") {
        $schedule.lastStatus = "interrupted"
        $schedule.lastResultCode = "panel-restarted"
        $schedule.lastMessage = "面板在等待检查结果时重新启动，本次结果未能恢复；可点击立即检查重新执行。"
    }
}
Save-MaintenanceSchedules

Remove-Item -LiteralPath $stopRequestPath -Force -ErrorAction SilentlyContinue
$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add("http://+:$Port/")
$listener.Start()
$panelLanAddress = Get-PrimaryLanAddress
[IO.File]::WriteAllText($pidPath, ([ordered]@{
    pid = $PID; port = $Port; startedAt = (Get-Date).ToString("o"); url = "http://$panelLanAddress`:$Port/"
} | ConvertTo-Json), $utf8)
Add-Audit -Remote "local" -Action "panel-start" -Detail "port=$Port" -Result "ok"

try {
    while ($listener.IsListening) {
        if (Test-Path -LiteralPath $stopRequestPath -PathType Leaf) { break }
        $pendingContext = $listener.BeginGetContext($null, $null)
        $stopRequested = $false
        while ($listener.IsListening -and -not $pendingContext.AsyncWaitHandle.WaitOne(200)) {
            Invoke-AIBridgeTick
            Invoke-MaintenanceSchedulerTick
            Invoke-BroadcastSchedulerTick
            Invoke-ExecutionHistoryTick
            if (Test-Path -LiteralPath $stopRequestPath -PathType Leaf) {
                $stopRequested = $true
                break
            }
        }
        if (-not $listener.IsListening -or $stopRequested) { break }
        $context = $listener.EndGetContext($pendingContext)
        Invoke-AIBridgeTick
        Invoke-MaintenanceSchedulerTick
        Invoke-BroadcastSchedulerTick
        Invoke-ExecutionHistoryTick
        $requestStartedAt = Get-Date
        try {
            $request = $context.Request
            $path = $request.Url.AbsolutePath
            [IO.File]::WriteAllText($requestStatePath, ([ordered]@{
                status = "active"
                method = [string]$request.HttpMethod
                path = [string]$request.RawUrl
                remote = [string]$request.RemoteEndPoint.Address
                startedAt = $requestStartedAt.ToString("o")
            } | ConvertTo-Json), $utf8)
            if ($path -eq "/" -or $path -eq "/index.html") {
                $html = Get-Content -LiteralPath (Join-Path $webRoot "index.html") -Raw -Encoding UTF8
                Write-TextResponse $context 200 $html "text/html"
                continue
            }
            if ($path -eq "/app.css") {
                Write-TextResponse $context 200 (Get-Content -LiteralPath (Join-Path $webRoot "app.css") -Raw -Encoding UTF8) "text/css"
                continue
            }
            if ($path -eq "/app.js") {
                Write-TextResponse $context 200 (Get-Content -LiteralPath (Join-Path $webRoot "app.js") -Raw -Encoding UTF8) "application/javascript"
                continue
            }
            if ($path -eq "/lucide.min.js") {
                Write-TextResponse $context 200 (Get-Content -LiteralPath (Join-Path $webRoot "lucide.min.js") -Raw -Encoding UTF8) "application/javascript"
                continue
            }
            if ($path -eq "/qrcode.min.js") {
                Write-TextResponse $context 200 (Get-Content -LiteralPath (Join-Path $webRoot "qrcode.min.js") -Raw -Encoding UTF8) "application/javascript"
                continue
            }
            if ($request.HttpMethod -eq "GET" -and $path -eq "/api/auth/session") {
                $session = Get-AuthenticatedSession -Request $request
                $users = @(Read-Users)
                Write-JsonResponse $context 200 @{
                    ok = $true
                    authenticated = [bool]$session
                    setupRequired = $users.Count -eq 0
                    local = Test-LocalRequest $request
                    user = if ($session) { Get-PublicUser $session.user } else { $null }
                    csrf = if ($session) { [string]$session.csrf } else { $null }
                }
                continue
            }
            if ($request.HttpMethod -eq "POST" -and $path -eq "/api/auth/setup") {
                if (-not (Test-LocalRequest $request)) {
                    Write-JsonResponse $context 403 @{ ok = $false; error = "第一个管理员只能在服务器本机 127.0.0.1 页面创建。" }
                    continue
                }
                if (@(Read-Users).Count -gt 0) { throw "管理员已经初始化，请直接登录。" }
                $body = Get-RequestBody $request
                $user = New-PanelUser -Username "admin" -DisplayName ([string]$body.displayName) -Password ([string]$body.password)
                Save-Users -Users @($user)
                $created = New-AuthenticatedSession -User $user
                Set-SessionCookie -Response $context.Response -Token $created.token
                Add-Audit -Remote "local" -Action "auth-setup" -Detail "username=$($user.username)" -Result "ok"
                Write-JsonResponse $context 201 @{ ok = $true; message = "管理员已创建。"; user = Get-PublicUser $user; csrf = $created.session.csrf }
                continue
            }
            if ($request.HttpMethod -eq "POST" -and $path -eq "/api/auth/login") {
                $remote = $request.RemoteEndPoint.Address.ToString()
                if (-not (Test-LoginAllowed -Remote $remote)) {
                    Write-JsonResponse $context 429 @{ ok = $false; error = "登录失败次数过多，请 15 分钟后重试。" }
                    continue
                }
                $body = Get-RequestBody $request
                $username = ([string]$body.username).Trim()
                $user = Read-Users | Where-Object { [string]$_.username -ieq $username } | Select-Object -First 1
                $valid = $false
                if ($user -and [bool]$user.enabled) {
                    try {
                        $salt = [Convert]::FromBase64String([string]$user.passwordSalt)
                        $expected = [Convert]::FromBase64String([string]$user.passwordHash)
                        $actual = Get-PasswordHash -Password ([string]$body.password) -Salt $salt -Iterations ([int]$user.iterations)
                        $valid = Test-FixedTimeEqual -Left $expected -Right $actual
                    }
                    catch { $valid = $false }
                }
                if (-not $valid) {
                    Add-LoginFailure -Remote $remote
                    Add-Audit -Remote $remote -Action "auth-login" -Detail "username=$username" -Result "failed"
                    Write-JsonResponse $context 401 @{ ok = $false; error = "登录名或密码错误。" }
                    continue
                }
                $loginAttempts.Remove($remote)
                $created = New-AuthenticatedSession -User $user
                Set-SessionCookie -Response $context.Response -Token $created.token
                Add-Audit -Remote $remote -Action "auth-login" -Detail "username=$($user.username)" -Result "ok"
                Write-JsonResponse $context 200 @{ ok = $true; message = "登录成功。"; user = Get-PublicUser $user; csrf = $created.session.csrf; local = Test-LocalRequest $request }
                continue
            }
            if ($request.HttpMethod -eq "POST" -and $path -eq "/api/auth/logout") {
                $session = Get-AuthenticatedSession -Request $request
                $token = Get-RequestCookieValue -Request $request -Name $sessionCookieName
                if ($session -and (Test-Csrf -Request $request -Session $session)) { $sessions.Remove($token) }
                Clear-SessionCookie -Response $context.Response
                Write-JsonResponse $context 200 @{ ok = $true; message = "已退出登录。" }
                continue
            }

            $session = Get-AuthenticatedSession -Request $request
            if (-not $session) {
                Write-JsonResponse $context 401 @{ ok = $false; error = "请先登录。" }
                continue
            }
            if ($request.HttpMethod -ne "GET" -and -not (Test-Csrf -Request $request -Session $session)) {
                Write-JsonResponse $context 403 @{ ok = $false; error = "请求校验失败，请刷新页面后重试。" }
                continue
            }
            if ($path -like "/api/users*") {
                if (-not (Test-LocalRequest $request)) {
                    Write-JsonResponse $context 403 @{ ok = $false; error = "Web 用户只能在服务器本机 127.0.0.1 页面管理。" }
                    continue
                }
                if ($request.HttpMethod -eq "GET" -and $path -eq "/api/users") {
                    Write-JsonResponse $context 200 @{ ok = $true; users = @(Read-Users | ForEach-Object { Get-PublicUser $_ }) }
                    continue
                }
                if ($request.HttpMethod -eq "POST" -and $path -eq "/api/users") {
                    $body = Get-RequestBody $request
                    $users = @(Read-Users)
                    $username = Assert-LoginName ([string]$body.username)
                    if ($username -ieq "admin") { throw "admin 是系统保留管理员账号。" }
                    if ($users | Where-Object { [string]$_.username -ieq $username }) { throw "登录名已存在。" }
                    Assert-HostControlAdministrator -Session $session
                    $user = New-PanelUser -Username $username -DisplayName ([string]$body.displayName) -Password ([string]$body.password) -Enabled $true -CanManagePlayerData ([bool]$body.canManagePlayerData)
                    Save-Users -Users (@($users) + @($user))
                    Add-Audit -Remote "local" -Action "user-create" -Detail "username=$username" -Result "ok"
                    Write-JsonResponse $context 201 @{ ok = $true; message = "用户已创建。"; user = Get-PublicUser $user }
                    continue
                }
                if ($request.HttpMethod -eq "PUT" -and $path -eq "/api/users") {
                    Assert-HostControlAdministrator -Session $session
                    $body = Get-RequestBody $request
                    $users = @(Read-Users)
                    $user = $users | Where-Object { [string]$_.id -ceq [string]$body.id } | Select-Object -First 1
                    if (-not $user) { throw "用户不存在。" }
                    $username = Assert-LoginName ([string]$body.username)
                    $isAdmin = [string]$user.username -ieq "admin"
                    if ($isAdmin -and $username -ine "admin") { throw "admin 管理员账号不能重命名。" }
                    if ($users | Where-Object { [string]$_.id -cne [string]$user.id -and [string]$_.username -ieq $username }) { throw "登录名已存在。" }
                    $enabled = [bool]$body.enabled
                    if ($isAdmin -and -not $enabled) { throw "admin 管理员账号不能禁用。" }
                    if (-not $enabled -and [bool]$user.enabled -and @($users | Where-Object { [bool]$_.enabled }).Count -le 1) {
                        throw "不能禁用最后一个可登录用户。"
                    }
                    $invalidate = [bool]$user.enabled -and -not $enabled
                    $user.username = $username
                    $user.displayName = Assert-SimpleText -Value ([string]$body.displayName) -Name "显示名称" -MaxLength 64
                    $user.enabled = $enabled
                    $canManagePlayerData = $isAdmin -or [bool]$body.canManagePlayerData
                    if ($user.PSObject.Properties["canManagePlayerData"]) { $user.canManagePlayerData = $canManagePlayerData }
                    else { $user | Add-Member -NotePropertyName "canManagePlayerData" -NotePropertyValue $canManagePlayerData }
                    if (-not [string]::IsNullOrWhiteSpace([string]$body.password)) {
                        $password = Assert-PanelPassword ([string]$body.password)
                        $salt = [byte[]]::new(32)
                        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
                        try { $rng.GetBytes($salt) } finally { $rng.Dispose() }
                        $user.passwordSalt = [Convert]::ToBase64String($salt)
                        $user.passwordHash = [Convert]::ToBase64String((Get-PasswordHash -Password $password -Salt $salt -Iterations $passwordIterations))
                        $user.iterations = $passwordIterations
                        $invalidate = $true
                    }
                    if ($invalidate) { $user.sessionVersion = [int]$user.sessionVersion + 1 }
                    $user.updatedAt = (Get-Date).ToString("o")
                    Save-Users -Users $users
                    Add-Audit -Remote "local" -Action "user-update" -Detail "username=$username" -Result "ok"
                    Write-JsonResponse $context 200 @{ ok = $true; message = "用户已更新。"; user = Get-PublicUser $user }
                    continue
                }
                if ($request.HttpMethod -eq "DELETE" -and $path -eq "/api/users") {
                    Assert-HostControlAdministrator -Session $session
                    $body = Get-RequestBody $request
                    if ([string]$body.confirm -cne "DELETE_USER") { throw "删除用户需要二次确认。" }
                    $users = @(Read-Users)
                    $user = $users | Where-Object { [string]$_.id -ceq [string]$body.id } | Select-Object -First 1
                    if (-not $user) { throw "用户不存在。" }
                    if ([string]$user.username -ieq "admin") { throw "admin 管理员账号不能删除。" }
                    if ([bool]$user.enabled -and @($users | Where-Object { [bool]$_.enabled }).Count -le 1) { throw "不能删除最后一个可登录用户。" }
                    Save-Users -Users @($users | Where-Object { [string]$_.id -cne [string]$user.id })
                    Add-Audit -Remote "local" -Action "user-delete" -Detail "username=$($user.username)" -Result "ok"
                    Write-JsonResponse $context 200 @{ ok = $true; message = "用户已删除。" }
                    continue
                }
            }
            if ($path -like "/api/ai/config*" -or $path -eq "/api/ai/models" -or $path -eq "/api/ai/test" -or $path -eq "/api/ai/clear-history" -or $path -eq "/api/ai/policies" -or $path -eq "/api/ai/runtime" -or $path -eq "/api/ai/moderation" -or $path -eq "/api/ai/knowledge/open" -or $path -eq "/api/ai/knowledge/build") {
                $aiRemote = $request.RemoteEndPoint.Address.ToString()
                if ($request.HttpMethod -eq "GET" -and $path -eq "/api/ai/config") {
                    Write-JsonResponse $context 200 (Get-PublicAIConfig)
                    continue
                }
                if ($request.HttpMethod -eq "PUT" -and $path -eq "/api/ai/config") {
                    $body = Get-RequestBody $request
                    $saved = Set-AIConfig -Body $body
                    Add-Audit -Remote $aiRemote -Action "ai-config-update" -Detail "provider=$($saved.provider) model=$($saved.model) enabled=$($saved.enabled) servers=$(@($saved.serverIds).Count) keyConfigured=$($saved.apiKeyConfigured)" -Result "ok"
                    $responsePayload = [ordered]@{ message = "AI 助手配置已保存并立即生效。" }
                    foreach ($property in @($saved.Keys)) { $responsePayload[$property] = $saved[$property] }
                    Write-JsonResponse $context 200 $responsePayload
                    continue
                }
                if ($request.HttpMethod -eq "POST" -and $path -eq "/api/ai/models") {
                    $body = Get-RequestBody $request
                    $result = Get-AIProviderModels -Body $body
                    Add-Audit -Remote $aiRemote -Action "ai-models-fetch" -Detail "provider=$([string]$body.provider) count=$($result.count)" -Result "ok"
                    Write-JsonResponse $context 200 $result
                    continue
                }
                if ($request.HttpMethod -eq "POST" -and $path -eq "/api/ai/test") {
                    $result = Test-AIConnection
                    Add-Audit -Remote $aiRemote -Action "ai-connection-test" -Detail "provider=$($result.provider) model=$($result.model)" -Result "ok"
                    Write-JsonResponse $context 200 $result
                    continue
                }
                if ($request.HttpMethod -eq "POST" -and $path -eq "/api/ai/clear-history") {
                    Clear-AIHistory
                    Add-Audit -Remote $aiRemote -Action "ai-history-clear" -Detail "all player AI conversations" -Result "ok"
                    Write-JsonResponse $context 200 @{ ok = $true; message = "玩家 AI 会话记录已清空。" }
                    continue
                }
                if ($request.HttpMethod -eq "POST" -and $path -eq "/api/ai/runtime") {
                    $body = Get-RequestBody $request
                    $action = ([string]$body.action).Trim().ToLowerInvariant()
                    $result = Invoke-AIBridgeRuntimeAction -Action $action
                    Add-Audit -Remote $aiRemote -Action "ai-bridge-$action" -Detail "integrated web bridge" -Result "ok"
                    $payload = [ordered]@{ message = "内置 AI Bridge 已$($(switch ($action) { 'start' { '启动' } 'stop' { '停止' } 'restart' { '重启' } }))。" }
                    foreach ($property in @($result.Keys)) { $payload[$property] = $result[$property] }
                    Write-JsonResponse $context 200 $payload
                    continue
                }
                if ($request.HttpMethod -eq "POST" -and $path -eq "/api/ai/knowledge/open") {
                    if (-not (Test-LocalRequest $request)) {
                        throw "服务器信息库只能在运行 Web 面板的 Windows 主机上打开；远程访问请使用面板主机的远程桌面或文件共享。"
                    }
                    New-Item -ItemType Directory -Path $aiKnowledgeRoot -Force | Out-Null
                    Start-Process -FilePath "explorer.exe" -ArgumentList @($aiKnowledgeRoot) -WindowStyle Normal | Out-Null
                    Add-Audit -Remote $aiRemote -Action "ai-knowledge-open" -Detail "server information library opened on panel host" -Result "ok"
                    Write-JsonResponse $context 200 @{ ok = $true; message = "已在面板主机打开服务器信息库。" ; directory = "服务器信息库" }
                    continue
                }
                if ($request.HttpMethod -eq "GET" -and $path -eq "/api/ai/knowledge/build") {
                    Write-JsonResponse $context 200 (Get-AIKnowledgeBuildStatus)
                    continue
                }
                if ($request.HttpMethod -eq "POST" -and $path -eq "/api/ai/knowledge/build") {
                    if ([string]$session.user.username -ine "admin") {
                        Write-JsonResponse $context 403 @{ ok = $false; error = "只有 Web admin 管理员可以调用付费模型构建知识库。" }
                        continue
                    }
                    $body = Get-RequestBody $request
                    if ([string]$body.confirm -cne "BUILD_AI_KNOWLEDGE") { throw "构建知识库需要确认模型调用和可能产生的 API 费用。" }
                    $result = Start-AIKnowledgeBuild -Body $body
                    Add-Audit -Remote $aiRemote -Action "ai-knowledge-build" -Detail "server=$($result.serverId) provider=$($result.provider) model=$($result.model) effort=$($result.reasoningEffort) chunks=$($result.totalChunks)" -Result "queued"
                    Write-JsonResponse $context 202 $result
                    continue
                }
                if ($request.HttpMethod -eq "DELETE" -and $path -eq "/api/ai/knowledge/build") {
                    if ([string]$session.user.username -ine "admin") {
                        Write-JsonResponse $context 403 @{ ok = $false; error = "只有 Web admin 管理员可以取消知识库构建。" }
                        continue
                    }
                    $body = Get-RequestBody $request
                    if ([string]$body.confirm -cne "CANCEL_AI_KNOWLEDGE") { throw "取消知识库构建需要二次确认。" }
                    $result = Stop-AIKnowledgeBuild
                    Add-Audit -Remote $aiRemote -Action "ai-knowledge-cancel" -Detail "id=$($result.id) server=$($result.serverId)" -Result "ok"
                    Write-JsonResponse $context 200 $result
                    continue
                }
                if ($request.HttpMethod -eq "GET" -and $path -eq "/api/ai/policies") {
                    Write-JsonResponse $context 200 (Get-PublicAIOperationPolicies)
                    continue
                }
                if ($request.HttpMethod -eq "GET" -and $path -eq "/api/ai/moderation") {
                    Write-JsonResponse $context 200 (Get-AIModerationRecords)
                    continue
                }
                if ($request.HttpMethod -eq "PUT" -and $path -eq "/api/ai/moderation") {
                    $body = Get-RequestBody $request
                    $eventId = Assert-SimpleText -Value ([string]$body.id) -Name "审查事件 ID" -MaxLength 64
                    $reviewStatus = Assert-SimpleText -Value ([string]$body.status) -Name "复核状态" -MaxLength 32
                    $reviewNote = ([string]$body.note).Trim()
                    $payload = Set-AIModerationReview -Id $eventId -Status $reviewStatus -Note $reviewNote
                    Add-Audit -Remote $aiRemote -Action "ai-moderation-review" -Detail "id=$eventId status=$reviewStatus" -Result "ok"
                    $payload.message = "AI 审查事件复核状态已更新。"
                    Write-JsonResponse $context 200 $payload
                    continue
                }
                if ($request.HttpMethod -in @("POST", "PUT") -and $path -eq "/api/ai/policies") {
                    $body = Get-RequestBody $request
                    $profile = Get-ServerProfile -Id ([string]$body.serverId)
                    $username = Assert-SimpleText -Value ([string]$body.username) -Name "玩家名" -MaxLength 64
                    $steamId = ([string]$body.steamId).Trim()
                    if ($steamId -notmatch '^7656119\d{10}$') { throw "SteamID64 格式无效，应为 7656119 开头的 17 位数字。" }
                    $catalogIds = @(Get-AIOperationCatalog | ForEach-Object { [string]$_.id })
                    $allowedOperations = @($body.allowedOperations | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique)
                    foreach ($operationId in $allowedOperations) {
                        if ($operationId -notin $catalogIds) { throw "未知的 AI 操作权限：$operationId" }
                    }
                    $now = (Get-Date).ToString("o")
                    if ($request.HttpMethod -eq "POST") {
                        if ($aiOperationPolicies | Where-Object { [string]$_.serverId -ceq [string]$profile.id -and [string]$_.username -ieq $username -and [string]$_.steamId -ceq $steamId }) {
                            throw "该服务器、玩家名和 SteamID 的授权已经存在。"
                        }
                        $policy = [pscustomobject][ordered]@{
                            id = [guid]::NewGuid().ToString("N"); serverId = [string]$profile.id; username = $username; steamId = $steamId
                            enabled = [bool]$body.enabled; trustedAll = [bool]$body.trustedAll; allowedOperations = @($allowedOperations)
                            createdAt = $now; updatedAt = $now
                        }
                        $script:aiOperationPolicies = @($aiOperationPolicies) + $policy
                    }
                    else {
                        $policy = $aiOperationPolicies | Where-Object { [string]$_.id -ceq [string]$body.id } | Select-Object -First 1
                        if (-not $policy) { throw "AI 玩家授权不存在。" }
                        if ($aiOperationPolicies | Where-Object { [string]$_.id -cne [string]$policy.id -and [string]$_.serverId -ceq [string]$profile.id -and [string]$_.username -ieq $username -and [string]$_.steamId -ceq $steamId }) {
                            throw "该服务器、玩家名和 SteamID 的授权已经存在。"
                        }
                        $policy.serverId = [string]$profile.id; $policy.username = $username; $policy.steamId = $steamId
                        $policy.enabled = [bool]$body.enabled; $policy.trustedAll = [bool]$body.trustedAll
                        $policy.allowedOperations = @($allowedOperations); $policy.updatedAt = $now
                    }
                    Save-AIOperationPolicies
                    Add-Audit -Remote $aiRemote -Action "ai-policy-save" -Detail "server=$($profile.id) username=$username steamId=$steamId trustedAll=$([bool]$body.trustedAll) operations=$($allowedOperations.Count)" -Result "ok"
                    $payload = Get-PublicAIOperationPolicies
                    $payload.message = "AI 玩家授权已保存。当前执行器尚未接入，因此该配置不会立即执行游戏操作。"
                    Write-JsonResponse $context $(if ($request.HttpMethod -eq "POST") { 201 } else { 200 }) $payload
                    continue
                }
                if ($request.HttpMethod -eq "DELETE" -and $path -eq "/api/ai/policies") {
                    $body = Get-RequestBody $request
                    if ([string]$body.confirm -cne "DELETE_AI_POLICY") { throw "删除 AI 玩家授权需要二次确认。" }
                    $policy = $aiOperationPolicies | Where-Object { [string]$_.id -ceq [string]$body.id } | Select-Object -First 1
                    if (-not $policy) { throw "AI 玩家授权不存在。" }
                    $script:aiOperationPolicies = @($aiOperationPolicies | Where-Object { [string]$_.id -cne [string]$policy.id })
                    Save-AIOperationPolicies
                    Add-Audit -Remote $aiRemote -Action "ai-policy-delete" -Detail "server=$($policy.serverId) username=$($policy.username) steamId=$($policy.steamId)" -Result "ok"
                    $payload = Get-PublicAIOperationPolicies
                    $payload.message = "AI 玩家授权已删除。"
                    Write-JsonResponse $context 200 $payload
                    continue
                }
            }
            if ($request.HttpMethod -eq "GET" -and $path -eq "/api/ai/status") {
                Write-JsonResponse $context 200 (Get-AIBridgeStatus)
                continue
            }
            if ($request.HttpMethod -eq "GET" -and $path -eq "/api/ai/requests") {
                Write-JsonResponse $context 200 (Get-AIRequestRecords)
                continue
            }
            if ($request.HttpMethod -eq "GET" -and $path -eq "/api/ai/log") {
                $tail = 200
                if ($request.QueryString["tail"]) { [void][int]::TryParse([string]$request.QueryString["tail"], [ref]$tail) }
                Write-JsonResponse $context 200 (Get-AIBridgeLog -Tail $tail)
                continue
            }
            if ($request.HttpMethod -eq "GET" -and $path -eq "/api/status") {
                if (-not $statusCache -or ((Get-Date) - $statusCacheAt).TotalSeconds -ge 3) {
                    $states = @($serverProfiles | ForEach-Object { Get-ServerState -Profile $_ })
                    $statusCache = @{ ok = $true; servers = $states; defaultServer = [string]$profileConfig.defaultServer }
                    $statusCacheAt = Get-Date
                }
                $statusCache.serverTime = (Get-Date).ToString("o")
                Write-JsonResponse $context 200 $statusCache
                continue
            }
            if ($request.HttpMethod -eq "GET" -and $path -in @("/api/map-reset/config", "/api/map-reset/status")) {
                $profile = Get-ServerProfile -Id ([string]$request.QueryString["serverId"])
                Write-JsonResponse $context 200 (Get-MapResetPayload -Profile $profile -Session $session)
                continue
            }
            if ($request.HttpMethod -eq "PUT" -and $path -eq "/api/map-reset/config") {
                Assert-HostControlAdministrator -Session $session
                $body = Get-RequestBody $request
                $profile = Get-ServerProfile -Id ([string]$body.serverId)
                $current = Complete-MapResetStatus -Profile $profile
                if ($current -and [string]$current.state -in @("running", "finalizing")) { throw "地图刷新任务执行期间不能修改保护配置。" }
                $config = ConvertTo-NormalizedMapResetConfig -Profile $profile -Body $body
                Save-MapResetConfig -Profile $profile -Config $config
                Add-Audit -Remote $request.RemoteEndPoint.Address.ToString() -Action "map-reset-config-save" `
                    -Detail "server=$($profile.id) safehouseMargin=$($config.safehouseMarginChunks) playerMargin=$($config.playerMarginChunks) manualAreas=$(@($config.manualAreas).Count) requestedBy=$($session.user.username)" -Result "ok"
                $payload = Get-MapResetPayload -Profile $profile -Session $session
                $payload.message = "地图刷新保护配置已保存；修改后需要重新运行只读审计。"
                Write-JsonResponse $context 200 $payload
                continue
            }
            if ($request.HttpMethod -eq "POST" -and $path -in @("/api/map-reset/audit", "/api/map-reset/apply")) {
                Assert-HostControlAdministrator -Session $session
                $body = Get-RequestBody $request
                $profile = Get-ServerProfile -Id ([string]$body.serverId)
                $config = Get-MapResetConfig -Profile $profile
                $mode = if ($path -eq "/api/map-reset/apply") { "apply" } else { "audit" }
                $confirmation = if ($mode -eq "apply") { [string]$body.confirmation } else { "" }
                $operation = Start-MapResetOperation -Profile $profile -Config $config -Mode $mode -Confirmation $confirmation
                Add-Audit -Remote $request.RemoteEndPoint.Address.ToString() -Action "map-reset-$mode" `
                    -Detail "server=$($profile.id) operation=$($operation.operationId) configHash=$($operation.configHash) requestedBy=$($session.user.username)" -Result "queued"
                $payload = Get-MapResetPayload -Profile $profile -Session $session
                $payload.message = if ($mode -eq "audit") { "只读审计已在后台启动。" } else { "选择性区块刷新已在后台启动；完成后不会自动启动服务器。" }
                Write-JsonResponse $context 202 $payload
                continue
            }
            if ($path -like "/api/profiles*") {
                if (-not (Test-LocalRequest $request)) {
                    Write-JsonResponse $context 403 @{ ok = $false; error = "未启用访问令牌时，服务器配置只能在服务器本机编辑。" }
                    continue
                }
                if ($request.HttpMethod -eq "GET" -and $path -eq "/api/profiles") {
                    Write-JsonResponse $context 200 @{ ok = $true; defaultServer = [string]$profileConfig.defaultServer; profiles = $serverProfiles }
                    continue
                }
                if ($request.HttpMethod -eq "POST" -and $path -eq "/api/profiles/scan") {
                    $discovered = @(Find-RunningPZServers)
                    if ($discovered.Count -gt 0) {
                        Save-ServerProfiles -Profiles (@($serverProfiles) + $discovered) -DefaultServer ([string]$profileConfig.defaultServer)
                    }
                    Add-Audit -Remote $request.RemoteEndPoint.Address.ToString() -Action "profile-scan" -Detail "added=$($discovered.Count)" -Result "ok"
                    $message = if ($discovered.Count -gt 0) { "已自动添加 $($discovered.Count) 个正在运行的 PZ 服务器。" } else { "没有发现尚未配置的运行中 PZ 服务器。" }
                    Write-JsonResponse $context 200 @{ ok = $true; message = $message; added = $discovered.Count; profiles = $discovered }
                    continue
                }
                if ($request.HttpMethod -eq "POST" -and $path -eq "/api/profiles/save") {
                    $body = Get-RequestBody $request
                    $mode = [string]$body.mode
                    if ($mode -notin @("create", "update")) { throw "配置保存模式无效。" }
                    $requestedId = ([string]$body.profile.id).Trim().ToLowerInvariant()
                    $existing = $serverProfiles | Where-Object { [string]$_.id -ceq $requestedId } | Select-Object -First 1
                    if ($mode -eq "update" -and $existing -and [string]$body.profile.commandChannel -eq "queue" -and
                        [string]$existing.commandChannel -eq "queue") {
                        foreach ($field in @("queueDir", "statePath", "startScript", "stopScript")) {
                            if ([string]::IsNullOrWhiteSpace([string]$body.profile.$field)) { $body.profile | Add-Member -NotePropertyName $field -NotePropertyValue $existing.$field -Force }
                        }
                    }
                    if ($mode -eq "update" -and $existing -and
                        $body.profile.PSObject.Properties.Name -notcontains "streamingStabilityOptions") {
                        $body.profile | Add-Member -NotePropertyName streamingStabilityOptions -NotePropertyValue $existing.streamingStabilityOptions -Force
                    }
                    $profile = ConvertTo-ServerProfile -InputProfile $body.profile
                    if ($mode -eq "create" -and $existing) { throw "服务器 ID 已存在。" }
                    if ($mode -eq "update" -and -not $existing) { throw "要编辑的服务器配置不存在。" }
                    if ($mode -eq "update" -and (Get-ServerState -Profile $existing).alive -and (Test-ProfileIdentityChanged -OldProfile $existing -NewProfile $profile)) {
                        throw "服务器运行中不能修改 Java 路径，因为该路径用于识别当前进程；其他配置可立即修改。"
                    }
                    Ensure-ManagedProfile -Profile $profile
                    $nextProfiles = if ($mode -eq "create") {
                        @($serverProfiles) + @($profile)
                    }
                    else {
                        @($serverProfiles | ForEach-Object { if ([string]$_.id -ceq [string]$profile.id) { $profile } else { $_ } })
                    }
                    Save-ServerProfiles -Profiles $nextProfiles -DefaultServer ([string]$profileConfig.defaultServer)
                    $iniSync = Sync-PZProfileGameSettings -Profile $profile
                    Add-Audit -Remote $request.RemoteEndPoint.Address.ToString() -Action "profile-$mode" -Detail "server=$($profile.id) iniSynced=$([bool]$iniSync.updated) ini=$($iniSync.path)" -Result "ok"
                    $savedState = Get-ServerState -Profile $profile
                    $message = if ($iniSync.updated -and $savedState.alive) {
                        "配置已保存，端口和玩家上限已同步到游戏配置；重启游戏服务器后生效。"
                    } elseif ($iniSync.updated) {
                        "配置已保存，端口和玩家上限已同步到游戏配置；下次启动服务器时生效。"
                    } elseif ([string]$profile.commandChannel -eq "queue" -and $savedState.alive -and -not $savedState.writable) {
                        "配置和托管文件已自动生成。当前服务器无需停止；它下次自然停止后，请从面板启动，届时命令通道会自动接管。"
                    } elseif ($iniSync.reason -eq "missing") {
                        "面板配置已保存，但未找到游戏 INI：$($iniSync.path)。端口和玩家上限尚未同步到游戏。"
                    } else { "服务器配置已保存。" }
                    Write-JsonResponse $context 200 @{ ok = $true; message = $message; profile = $profile }
                    continue
                }
                if ($request.HttpMethod -eq "POST" -and $path -eq "/api/profiles/delete") {
                    $body = Get-RequestBody $request
                    if ($body.confirm -ne "DELETE_PROFILE") { throw "删除服务器配置需要二次确认。" }
                    $profile = Get-ServerProfile -Id ([string]$body.serverId)
                    if ((Get-ServerState -Profile $profile).alive) { throw "服务器仍在运行，不能删除配置。" }
                    if ($serverProfiles.Count -le 1) { throw "至少需要保留一个服务器配置。" }
                    $nextProfiles = @($serverProfiles | Where-Object { [string]$_.id -cne [string]$profile.id })
                    $defaultServer = if ([string]$profileConfig.defaultServer -ceq [string]$profile.id) { [string]$nextProfiles[0].id } else { [string]$profileConfig.defaultServer }
                    Save-ServerProfiles -Profiles $nextProfiles -DefaultServer $defaultServer
                    Add-Audit -Remote $request.RemoteEndPoint.Address.ToString() -Action "profile-delete" -Detail "server=$($profile.id)" -Result "ok"
                    Write-JsonResponse $context 200 @{ ok = $true; message = "服务器配置已删除；游戏文件和存档未删除。" }
                    continue
                }
                if ($request.HttpMethod -eq "POST" -and $path -eq "/api/profiles/default") {
                    $body = Get-RequestBody $request
                    $profile = Get-ServerProfile -Id ([string]$body.serverId)
                    Save-ServerProfiles -Profiles @($serverProfiles) -DefaultServer ([string]$profile.id)
                    Add-Audit -Remote $request.RemoteEndPoint.Address.ToString() -Action "profile-default" -Detail "server=$($profile.id)" -Result "ok"
                    Write-JsonResponse $context 200 @{ ok = $true; message = "$($profile.name) 已设为默认服务器。" }
                    continue
                }
            }
            if ($request.HttpMethod -eq "GET" -and $path -eq "/api/log") {
                $profile = Get-ServerProfile -Id ([string]$request.QueryString["serverId"])
                $after = 0L
                [void][long]::TryParse($request.QueryString["after"], [ref]$after)
                Write-JsonResponse $context 200 (@{ ok = $true; serverId = [string]$profile.id } + (Get-LogPayload -Profile $profile -After $after))
                continue
            }
            if ($request.HttpMethod -eq "GET" -and $path -eq "/api/chat") {
                $profile = Get-ServerProfile -Id ([string]$request.QueryString["serverId"])
                $after = 0L
                [void][long]::TryParse($request.QueryString["after"], [ref]$after)
                $payload = Get-ChatPayload -Profile $profile -After $after -RequestedFile ([string]$request.QueryString["file"])
                Write-JsonResponse $context 200 (@{ ok = $true; serverId = [string]$profile.id } + $payload)
                continue
            }
            if ($request.HttpMethod -eq "GET" -and $path -eq "/api/notices/status") {
                $profile = Get-ServerProfile -Id ([string]$request.QueryString["serverId"])
                Write-JsonResponse $context 200 (@{ ok = $true; serverId = [string]$profile.id; channel = Get-NoticeHeartbeat -Profile $profile })
                continue
            }
            if ($request.HttpMethod -eq "GET" -and $path -eq "/api/notices/receipt") {
                $profile = Get-ServerProfile -Id ([string]$request.QueryString["serverId"])
                Write-JsonResponse $context 200 (Get-NoticeReceiptPayload -Profile $profile -Id ([string]$request.QueryString["id"]))
                continue
            }
            if ($request.HttpMethod -eq "POST" -and $path -eq "/api/notices") {
                $body = Get-RequestBody $request
                $profile = Get-ServerProfile -Id ([string]$body.serverId)
                $serverState = Get-ServerState -Profile $profile
                if (-not $serverState.alive) { throw "服务器未运行，不能发送游戏内通知。" }
                $style = ([string]$body.style).ToLowerInvariant()
                if ($style -notin @("info", "success", "warning", "danger")) { throw "通知样式无效。" }
                $duration = [int]$body.duration
                if ($duration -lt 3 -or $duration -gt 300) { throw "显示时长必须为 3 至 300 秒。" }
                $titleSize = ([string]$body.titleSize).ToLowerInvariant()
                $bodySize = ([string]$body.bodySize).ToLowerInvariant()
                if ($titleSize -notin @("small", "medium", "large") -or $bodySize -notin @("small", "medium", "large")) { throw "通知字号无效。" }
                $accentColor = Normalize-NoticeColor -Value ([string]$body.accentColor) -Name "强调色"
                $textColor = Normalize-NoticeColor -Value ([string]$body.textColor) -Name "文字色"
                $title = Assert-NoticeUtf8Text -Value ([string]$body.title) -Name "通知标题" -MaxBytes 240
                $message = Assert-NoticeUtf8Text -Value ([string]$body.message) -Name "通知正文" -MaxBytes 4096 -AllowNewlines
                $targetType = ([string]$body.targetType).ToLowerInvariant()
                if ([string]::IsNullOrWhiteSpace($targetType)) { $targetType = "all" }
                if ($targetType -notin @("all", "player")) { throw "通知对象无效。" }
                $targetUsername = ""
                if ($targetType -eq "player") {
                    $targetUsername = Assert-NoticeUtf8Text -Value ([string]$body.targetUsername) -Name "目标玩家" -MaxBytes 64
                    $directory = Get-PlayerDirectory -Profile $profile
                    if (-not $directory.onlineKnown) { throw "当前无法确认在线玩家，不能发送定向通知。请先刷新玩家列表。" }
                    $onlineTarget = @($directory.players | Where-Object { $_.online -and [string]$_.username -ieq $targetUsername } | Select-Object -First 1)
                    if ($onlineTarget.Count -eq 0) { throw "目标玩家当前不在线，请刷新在线玩家列表后重试。" }
                    $targetUsername = [string]$onlineTarget[0].username
                }
                $heartbeat = Get-NoticeHeartbeat -Profile $profile
                if (-not $heartbeat.usable) {
                    if (-not $heartbeat.installed) { throw "本机未找到 PZWebNotices Mod，不能发送游戏内通知。" }
                    if ($heartbeat.status -eq "missing") { throw "尚未收到该服务器的通知 Mod 心跳。请确认该服务器已启用 PZWebNotices；首次启用后需要重启游戏服务器。" }
                    throw "通知 Mod 已超过 5 分钟没有心跳，当前不能确认通道可用。请检查服务器状态或 Mod 日志。"
                }
                try { $noticeVersion = [version]([string]$heartbeat.version) }
                catch { throw "通知 Mod 心跳没有可识别的版本号，无法确认 v3 队列兼容性。" }
                if ($noticeVersion -lt [version]"0.2.3") { throw "当前 PZWebNotices v$noticeVersion 不支持中文安全的 v3 队列，请升级到 0.2.3 或更高版本。" }
                if ($targetType -eq "player" -and [bool]$body.nativeBroadcast) { throw "指定玩家通知不能同时发送原生全服广播。" }
                if ([bool]$body.nativeBroadcast -and -not $serverState.writable) {
                    throw '当前服务器原生广播通道不可用，请关闭“同时发送原生广播”后重试。'
                }
                $id = "notice-" + [guid]::NewGuid().ToString("N")
                $expectedClients = if ($targetType -eq "player") { 1 } elseif ($serverState.onlineKnown) { [int]$serverState.onlineCount } else { 0 }
                $broadcastCommands = @()
                if ([bool]$body.nativeBroadcast) { $broadcastCommands = @(Get-BroadcastCommands -Message $message) }
                Add-NoticeQueueEntry -Profile $profile -Id $id -TargetType $targetType -TargetUsername $targetUsername -Style $style -Duration $duration -TitleSize $titleSize -BodySize $bodySize -AccentColor $accentColor -TextColor $textColor -Title $title -Message $message -ExpectedClients $expectedClients
                $fallbackRequestIds = @()
                $fallbackWarning = $null
                if ($broadcastCommands.Count -gt 0) {
                    $logCursor = 0L
                    if ($profile.consoleLog -and (Test-Path -LiteralPath ([string]$profile.consoleLog))) {
                        $logCursor = (Get-Item -LiteralPath ([string]$profile.consoleLog)).Length
                    }
                    try {
                        foreach ($command in $broadcastCommands) {
                            $queued = Queue-Command -Profile $profile -Command $command -RequireReceipt:$true
                            $fallbackRequestIds += [string]$queued.id
                            $commandRequests[[string]$queued.id] = [pscustomobject]@{
                                serverId = [string]$profile.id
                                action = "broadcast"
                                command = [string]$command
                                queuedAt = [string]$queued.createdAt
                                logCursor = $logCursor
                            }
                        }
                    }
                    catch { $fallbackWarning = $_.Exception.Message }
                }
                Add-Audit -Remote $request.RemoteEndPoint.Address.ToString() -Action "web-notice" -Detail "server=$($profile.id) id=$id target=$targetType/$targetUsername style=$style messageBytes=$($utf8.GetByteCount($message)) expectedClients=$expectedClients nativeBroadcast=$([bool]$body.nativeBroadcast)" -Result $(if ($fallbackWarning) { "queued-fallback-warning" } else { "queued" })
                $targetLabel = if ($targetType -eq "player") { "玩家 $targetUsername" } else { "全服玩家" }
                [void](Add-ExecutionHistoryRecord -ServerId ([string]$profile.id) -Category "broadcast" -Action "web-notice" -Source "web" `
                    -Summary "发送 Mod 弹窗给 $targetLabel" -Status $(if ($fallbackWarning) { "warning" } else { "queued" }) `
                    -Message $(if ($fallbackWarning) { "Mod 弹窗已提交；原生广播失败：$fallbackWarning" } else { "Mod 弹窗已提交，正在等待服务端和客户端回执。" }) `
                    -RequestIds $fallbackRequestIds -NoticeId $id -Detail "$title`n$message")
                Write-JsonResponse $context 202 @{ ok = $true; message = "右下角通知已进入 $($profile.name) 的 Mod 队列，目标：$targetLabel。"; id = $id; targetType = $targetType; targetUsername = $targetUsername; expectedClients = $expectedClients; fallbackRequestIds = $fallbackRequestIds; nativeBroadcastWarning = $fallbackWarning }
                continue
            }
            if ($request.HttpMethod -eq "GET" -and $path -eq "/api/command/result") {
                $profile = Get-ServerProfile -Id ([string]$request.QueryString["serverId"])
                Write-JsonResponse $context 200 (Get-CommandResultPayload -Profile $profile -Id ([string]$request.QueryString["id"]))
                continue
            }
            if ($request.HttpMethod -eq "GET" -and $path -eq "/api/command/results") {
                $profile = Get-ServerProfile -Id ([string]$request.QueryString["serverId"])
                $ids = @(([string]$request.QueryString["ids"]) -split ',')
                Write-JsonResponse $context 200 (Get-CommandResultsPayload -Profile $profile -Ids $ids)
                continue
            }
            if ($request.HttpMethod -eq "GET" -and $path -eq "/api/command/submission") {
                $profile = Get-ServerProfile -Id ([string]$request.QueryString["serverId"])
                Write-JsonResponse $context 200 (Get-CommandSubmissionPayload -Profile $profile -Id ([string]$request.QueryString["id"]))
                continue
            }
            if ($request.HttpMethod -eq "GET" -and $path -eq "/api/maintenance/save-backup") {
                $profile = Get-ServerProfile -Id ([string]$request.QueryString["serverId"])
                Write-JsonResponse $context 200 (Get-PZSaveBackupPayload -Profile $profile)
                continue
            }
            if ($request.HttpMethod -eq "GET" -and $path -eq "/api/maintenance/schedule") {
                $profile = Get-ServerProfile -Id ([string]$request.QueryString["serverId"])
                Write-JsonResponse $context 200 (Get-MaintenanceSchedulePayload -Profile $profile)
                continue
            }
            if ($request.HttpMethod -eq "GET" -and $path -eq "/api/broadcast-schedules") {
                $profile = Get-ServerProfile -Id ([string]$request.QueryString["serverId"])
                Write-JsonResponse $context 200 (Get-BroadcastSchedulesPayload -ServerId ([string]$profile.id))
                continue
            }
            if ($request.HttpMethod -in @("POST", "PUT") -and $path -eq "/api/broadcast-schedules") {
                $body = Get-RequestBody $request
                $profile = Get-ServerProfile -Id ([string]$body.serverId)
                $name = Assert-SimpleText -Value ([string]$body.name) -Name "任务名称" -MaxLength 64
                $channel = ([string]$body.channel).ToLowerInvariant()
                if ($channel -notin @("native", "popup", "both")) { throw "广播通道无效。" }
                $intervalMinutes = [int]$body.intervalMinutes
                if ($intervalMinutes -lt 5 -or $intervalMinutes -gt 10080) { throw "循环间隔必须为 5 至 10080 分钟。" }
                $title = ([string]$body.title).Trim()
                if ([string]::IsNullOrWhiteSpace($title)) { $title = "服务器通知" }
                $title = Assert-NoticeUtf8Text -Value $title -Name "弹窗标题" -MaxBytes 240
                $message = Assert-NoticeUtf8Text -Value ([string]$body.message -replace "`r", "") -Name "广播内容" -MaxBytes 4096 -AllowNewlines
                $duration = [int]$body.duration
                if ($duration -lt 3 -or $duration -gt 300) { throw "弹窗显示时长必须为 3 至 300 秒。" }
                $style = ([string]$body.style).ToLowerInvariant()
                if ($style -notin @("info", "success", "warning", "danger")) { throw "弹窗样式无效。" }
                $now = Get-Date
                if ($request.HttpMethod -eq "POST") {
                    $schedule = [pscustomobject][ordered]@{
                        id = [guid]::NewGuid().ToString("N"); serverId = [string]$profile.id; name = $name; enabled = [bool]$body.enabled
                        channel = $channel; intervalMinutes = $intervalMinutes; title = $title; message = $message; duration = $duration; style = $style
                        nextRunAt = if ([bool]$body.enabled) { $now.AddMinutes($intervalMinutes).ToString("o") } else { $null }
                        lastRunAt = $null; lastStatus = "never"; lastMessage = "尚未执行。"; createdAt = $now.ToString("o"); updatedAt = $now.ToString("o")
                    }
                    $script:broadcastSchedules = @($broadcastSchedules) + $schedule
                }
                else {
                    $schedule = $broadcastSchedules | Where-Object { [string]$_.id -ceq [string]$body.id } | Select-Object -First 1
                    if (-not $schedule) { throw "循环广播任务不存在。" }
                    $wasEnabled = [bool]$schedule.enabled
                    $schedule.serverId = [string]$profile.id; $schedule.name = $name; $schedule.enabled = [bool]$body.enabled
                    $schedule.channel = $channel; $schedule.intervalMinutes = $intervalMinutes; $schedule.title = $title
                    $schedule.message = $message; $schedule.duration = $duration; $schedule.style = $style; $schedule.updatedAt = $now.ToString("o")
                    if ($schedule.enabled -and (-not $wasEnabled -or [string]::IsNullOrWhiteSpace([string]$schedule.nextRunAt))) { $schedule.nextRunAt = $now.AddMinutes($intervalMinutes).ToString("o") }
                    elseif ($schedule.enabled -and $schedule.lastRunAt) { $schedule.nextRunAt = ([datetime]$schedule.lastRunAt).AddMinutes($intervalMinutes).ToString("o") }
                    elseif (-not $schedule.enabled) { $schedule.nextRunAt = $null }
                }
                Save-BroadcastSchedules
                Add-Audit -Remote $request.RemoteEndPoint.Address.ToString() -Action "broadcast-schedule-save" -Detail "server=$($profile.id) name=$name channel=$channel intervalMinutes=$intervalMinutes enabled=$([bool]$body.enabled)" -Result "ok"
                $payload = Get-BroadcastSchedulesPayload -ServerId ([string]$profile.id)
                $payload.message = "循环广播任务已保存。"
                Write-JsonResponse $context $(if ($request.HttpMethod -eq "POST") { 201 } else { 200 }) $payload
                continue
            }
            if ($request.HttpMethod -eq "DELETE" -and $path -eq "/api/broadcast-schedules") {
                $body = Get-RequestBody $request
                if ([string]$body.confirm -cne "DELETE_BROADCAST_SCHEDULE") { throw "删除循环广播任务需要二次确认。" }
                $schedule = $broadcastSchedules | Where-Object { [string]$_.id -ceq [string]$body.id } | Select-Object -First 1
                if (-not $schedule) { throw "循环广播任务不存在。" }
                $serverId = [string]$schedule.serverId
                $script:broadcastSchedules = @($broadcastSchedules | Where-Object { [string]$_.id -cne [string]$schedule.id })
                Save-BroadcastSchedules
                Add-Audit -Remote $request.RemoteEndPoint.Address.ToString() -Action "broadcast-schedule-delete" -Detail "server=$serverId name=$($schedule.name)" -Result "ok"
                $payload = Get-BroadcastSchedulesPayload -ServerId $serverId
                $payload.message = "循环广播任务已删除。"
                Write-JsonResponse $context 200 $payload
                continue
            }
            if ($request.HttpMethod -eq "POST" -and $path -eq "/api/broadcast-schedules/run-now") {
                $body = Get-RequestBody $request
                $schedule = $broadcastSchedules | Where-Object { [string]$_.id -ceq [string]$body.id } | Select-Object -First 1
                if (-not $schedule) { throw "循环广播任务不存在。" }
                Invoke-BroadcastSchedule -Schedule $schedule
                $payload = Get-BroadcastSchedulesPayload -ServerId ([string]$schedule.serverId)
                $payload.message = [string]$schedule.lastMessage
                Write-JsonResponse $context 202 $payload
                continue
            }
            if ($request.HttpMethod -eq "GET" -and $path -eq "/api/execution-history") {
                $serverId = ([string]$request.QueryString["serverId"]).Trim()
                if ($serverId) { [void](Get-ServerProfile -Id $serverId) }
                $category = ([string]$request.QueryString["category"]).Trim().ToLowerInvariant()
                if ($category -and $category -notin @("query", "command", "item", "broadcast", "update", "lifecycle")) {
                    throw "执行历史类型筛选无效。"
                }
                $page = 1
                $pageSize = 30
                if ($request.QueryString["page"]) { [void][int]::TryParse([string]$request.QueryString["page"], [ref]$page) }
                if ($request.QueryString["pageSize"]) { [void][int]::TryParse([string]$request.QueryString["pageSize"], [ref]$pageSize) }
                Write-JsonResponse $context 200 (Get-ExecutionHistoryPayload -ServerId $serverId -Category $category -Page $page -PageSize $pageSize)
                continue
            }
            if ($request.HttpMethod -eq "PUT" -and $path -eq "/api/maintenance/save-backup") {
                $body = Get-RequestBody $request
                $profile = Get-ServerProfile -Id ([string]$body.serverId)
                $payload = Set-PZSaveBackupSettings -Profile $profile `
                    -AutoSaveEnabled ([bool]$body.autoSaveEnabled) `
                    -SaveIntervalMinutes ([int]$body.saveIntervalMinutes) `
                    -AutoBackupEnabled ([bool]$body.autoBackupEnabled) `
                    -BackupIntervalMinutes ([int]$body.backupIntervalMinutes) `
                    -BackupCount ([int]$body.backupCount) `
                    -Remote $request.RemoteEndPoint.Address.ToString()
                Write-JsonResponse $context 200 $payload
                continue
            }
            if ($request.HttpMethod -eq "PUT" -and $path -eq "/api/maintenance/schedule") {
                $body = Get-RequestBody $request
                $profile = Get-ServerProfile -Id ([string]$body.serverId)
                $intervalHours = [int]$body.intervalHours
                if ($intervalHours -lt 1 -or $intervalHours -gt 168) { throw "自动检查间隔必须为 1 至 168 小时的整数。" }
                $restartStabilizationSeconds = [int]$body.restartStabilizationSeconds
                if ($restartStabilizationSeconds -eq 0) { $restartStabilizationSeconds = 60 }
                if ($restartStabilizationSeconds -lt 10 -or $restartStabilizationSeconds -gt 600) { throw "停服后启动缓冲必须为 10 至 600 秒。" }
                $schedule = Get-MaintenanceSchedule -ServerId ([string]$profile.id)
                $wasEnabled = [bool]$schedule.enabled
                $wasAutoRestartEnabled = [bool]$schedule.autoRestartOnUpdate
                $schedule.enabled = [bool]$body.enabled
                $schedule.intervalHours = $intervalHours
                $schedule.autoRestartOnUpdate = [bool]$body.autoRestartOnUpdate
                $schedule.restartStabilizationSeconds = $restartStabilizationSeconds
                if ($schedule.autoRestartOnUpdate -and -not $wasAutoRestartEnabled -and [string]$schedule.lastResultCode -eq "mods-update-required") {
                    $schedule.updateNotificationPending = $false
                    $schedule.lastMessage = "自动安全重启已启用；下次检查仍检测到 Mod 更新时，将发送 60 秒通知，旧 Java 停止后缓冲 $restartStabilizationSeconds 秒再启动。"
                }
                if ($schedule.enabled) {
                    if (-not $wasEnabled -or [string]::IsNullOrWhiteSpace([string]$schedule.nextRunAt)) {
                        $schedule.nextRunAt = (Get-Date).AddHours($intervalHours).ToString("o")
                    }
                    elseif ($schedule.lastRunAt) {
                        $schedule.nextRunAt = ([datetime]$schedule.lastRunAt).AddHours($intervalHours).ToString("o")
                    }
                }
                else { $schedule.nextRunAt = $null }
                Save-MaintenanceSchedules
                Add-Audit -Remote $request.RemoteEndPoint.Address.ToString() -Action "maintenance-schedule-save" -Detail "server=$($profile.id) enabled=$($schedule.enabled) intervalHours=$intervalHours stabilizationSeconds=$restartStabilizationSeconds" -Result "ok"
                $message = if ($schedule.autoRestartOnUpdate) {
                    "自动 Mod 检查计划已保存；发现更新后将发送 60 秒双通道通知，停服后缓冲 $restartStabilizationSeconds 秒再安全重启。"
                } else { "自动 Mod 检查计划已保存。" }
                Write-JsonResponse $context 200 (@{ message = $message } + (Get-MaintenanceSchedulePayload -Profile $profile))
                continue
            }
            if ($request.HttpMethod -eq "POST" -and $path -eq "/api/maintenance/check-now") {
                $body = Get-RequestBody $request
                $profile = Get-ServerProfile -Id ([string]$body.serverId)
                $payload = Start-ScheduledModCheck -Profile $profile -Manual
                Write-JsonResponse $context 202 (@{ message = [string]$payload.lastMessage } + $payload)
                continue
            }
            if ($request.HttpMethod -eq "GET" -and $path -eq "/api/server/program-update") {
                $profile = Get-ServerProfile -Id ([string]$request.QueryString["serverId"])
                Write-JsonResponse $context 200 (Get-PZProgramUpdateStatus -Profile $profile)
                continue
            }
            if ($request.HttpMethod -eq "POST" -and $path -eq "/api/server/program-update/check") {
                $body = Get-RequestBody $request
                $profile = Get-ServerProfile -Id ([string]$body.serverId)
                $payload = Get-PZProgramUpdateStatus -Profile $profile -QueryRemote
                $message = if ($payload.current) {
                    "游戏服务器本体已是 Steam public 分支最新版本（BuildID $($payload.remoteBuildId)），无需重复更新。服务器日志版本是程序内部标识，仅供参考；是否需要更新以 BuildID 比较结果为准。"
                }
                elseif ($payload.updateAvailable) {
                    "发现服务器程序更新：本地 $($payload.localBuildId)，public $($payload.remoteBuildId)。"
                }
                else {
                    "已取得 public BuildID $($payload.remoteBuildId)，但当前运行目录没有可比较的本地清单；执行一次安全更新后即可持续比较。"
                }
                $payload.message = $message
                [void](Add-ExecutionHistoryRecord -ServerId ([string]$profile.id) -Category "update" -Action "check-server-program-update" -Source "web" `
                    -Summary "检查服务器程序更新" -Status $(if ($payload.updateAvailable) { "warning" } else { "success" }) `
                    -Message $message -Detail ([string]$payload.detail))
                Add-Audit -Remote $request.RemoteEndPoint.Address.ToString() -Action "server-program-update-check" -Detail "server=$($profile.id) local=$($payload.localBuildId) remote=$($payload.remoteBuildId)" -Result "ok"
                Write-JsonResponse $context 200 $payload
                continue
            }
            if ($request.HttpMethod -eq "POST" -and $path -eq "/api/server/program-update/apply") {
                $body = Get-RequestBody $request
                $profile = Get-ServerProfile -Id ([string]$body.serverId)
                if ([string]$body.confirm -cne "SAVE_QUIT_UPDATE_RESTART") { throw "更新服务器程序需要二次确认。" }
                $activeOperation = Get-ActiveLifecycleOperation -Profile $profile
                if ($activeOperation) { throw "已有服务器生命周期操作正在执行：$($activeOperation.message)" }
                $serverState = Get-ServerState -Profile $profile
                if ($serverState.alive -and -not $serverState.canRestart) { throw "运行中的服务器必须先由面板受控，才能执行安全更新。$($serverState.note)" }
                if (-not $serverState.alive -and -not $serverState.canStart) { throw $serverState.startReason }
                if ([bool]$serverState.adminSetupRequired) { throw "游戏账号数据库已缺失，更新后无法无交互启动。请先完成首次 admin 初始化。" }
                $warningSeconds = [int]$body.warningSeconds
                if ($warningSeconds -eq 0) { $warningSeconds = 60 }
                if ($warningSeconds -lt 10 -or $warningSeconds -gt 600) { throw "更新通知倒计时必须为 10 至 600 秒。" }
                $schedule = Get-MaintenanceSchedule -ServerId ([string]$profile.id)
                $restartStabilizationSeconds = [int]$schedule.restartStabilizationSeconds
                $steamCmdPath = Find-SteamCmdPath -Profile $profile
                if (-not $steamCmdPath) { throw "找不到 steamcmd.exe，尚未停止服务器。请先安装 SteamCMD。" }
                $remote = Invoke-SteamCmdMetadataQuery -SteamCmdPath $steamCmdPath
                $operationId = Start-LifecycleOperation -Profile $profile -Action "update" -WarningSeconds $warningSeconds -RestartStabilizationSeconds $restartStabilizationSeconds -SteamCmdPath $steamCmdPath -RemoteBuildId ([string]$remote.buildId)
                $script:statusCache = $null
                $script:statusCacheAt = [datetime]::MinValue
                Add-Audit -Remote $request.RemoteEndPoint.Address.ToString() -Action "server-program-update" -Detail "server=$($profile.id) appId=380870 branch=public targetBuild=$($remote.buildId)" -Result "queued"
                [void](Add-ExecutionHistoryRecord -ServerId ([string]$profile.id) -Category "update" -Action "server-program-update" -Source "web" `
                    -Summary "安全更新服务器程序到 public Build $($remote.buildId)" -Status "queued" `
                    -Message "正在通知玩家；随后将保存、退出、更新服务器程序并重新启动。" -OperationId $operationId)
                Write-JsonResponse $context 202 @{ ok = $true; message = "安全更新已提交，目标 public BuildID 为 $($remote.buildId)。"; operationId = $operationId; remoteBuildId = [string]$remote.buildId }
                continue
            }
            if ($request.HttpMethod -eq "GET" -and $path -eq "/api/server/operation") {
                $profile = Get-ServerProfile -Id ([string]$request.QueryString["serverId"])
                Write-JsonResponse $context 200 (Get-LifecycleOperationPayload -Profile $profile -Id ([string]$request.QueryString["id"]))
                continue
            }
            if ($request.HttpMethod -eq "GET" -and $path -eq "/api/players") {
                $profile = Get-ServerProfile -Id ([string]$request.QueryString["serverId"])
                $directory = Get-PlayerDirectory -Profile $profile
                Write-JsonResponse $context 200 (@{ ok = $true; serverId = [string]$profile.id } + $directory)
                continue
            }
            if ($request.HttpMethod -eq "GET" -and $path -eq "/api/player-admin") {
                Assert-PlayerDataPermission -Session $session
                $profile = Get-ServerProfile -Id ([string]$request.QueryString["serverId"])
                $steamId = ([string]$request.QueryString["steamId"]).Trim()
                $snapshot = Invoke-PZPlayerDataManager -Profile $profile -Mode "inspect" -SteamId $steamId
                $serverState = Get-ServerState -Profile $profile
                $directory = Get-PlayerDirectory -Profile $profile
                $onlineLookup = @{}
                foreach ($player in @($directory.players | Where-Object { [bool]$_.online })) {
                    $onlineLookup[([string]$player.username).ToLowerInvariant()] = $true
                }
                $accounts = @($snapshot.accounts | ForEach-Object {
                    [ordered]@{
                        username = [string]$_.username
                        displayName = [string]$_.displayName
                        lastConnection = [string]$_.lastConnection
                        steamId = [string]$_.steamId
                        ownerId = [string]$_.ownerId
                        authType = [string]$_.authType
                        role = [string]$_.role
                        online = [bool]$onlineLookup.ContainsKey(([string]$_.username).ToLowerInvariant())
                    }
                })
                $found = $accounts.Count -gt 0 -or @($snapshot.characters).Count -gt 0 -or [bool]$snapshot.allowed -or [bool]$snapshot.banned
                Add-Audit -Remote $request.RemoteEndPoint.Address.ToString() -Action "player-data-inspect" -Detail "server=$($profile.id) steamId=$steamId found=$found requestedBy=$($session.user.username)" -Result "ok"
                Write-JsonResponse $context 200 @{
                    ok = $true
                    serverId = [string]$profile.id
                    serverName = [string]$profile.name
                    steamId = $steamId
                    found = [bool]$found
                    accounts = $accounts
                    characters = @($snapshot.characters)
                    allowed = [bool]$snapshot.allowed
                    banned = [bool]$snapshot.banned
                    serverRunning = [bool]$serverState.alive
                    lifecycleActive = [bool](Get-ActiveLifecycleOperation -Profile $profile)
                }
                continue
            }
            if ($request.HttpMethod -eq "POST" -and $path -eq "/api/player-admin/password") {
                Assert-PlayerDataPermission -Session $session
                $body = Get-RequestBody $request
                $profile = Get-ServerProfile -Id ([string]$body.serverId)
                $steamId = ([string]$body.steamId).Trim()
                $username = Assert-SimpleText -Value ([string]$body.username) -Name "用户名" -MaxLength 64
                $password = [string]$body.password
                $passwordConfirm = [string]$body.passwordConfirm
                if (-not [string]::Equals($password, $passwordConfirm, [StringComparison]::Ordinal)) { throw "两次输入的新密码不一致。" }
                $snapshot = Invoke-PZPlayerDataManager -Profile $profile -Mode "inspect" -SteamId $steamId
                $account = @($snapshot.accounts | Where-Object { [string]$_.username -ieq $username } | Select-Object -First 1)
                if ($account.Count -eq 0) { throw "账号 $username 不属于 SteamID $steamId，已拒绝修改。" }
                $quotedUser = Quote-PZ -Value $username -Name "用户名"
                $quotedPassword = Quote-PZ -Value $password -Name "用户密码" -MaxLength 128
                try {
                    $queued = Queue-Command -Profile $profile -Command "setpassword $quotedUser $quotedPassword" -RequireReceipt:$true
                    $requestId = [string]$queued.id
                    $commandRequests[$requestId] = [pscustomobject]@{
                        serverId = [string]$profile.id
                        action = "player-password"
                        command = "[redacted]"
                        queuedAt = [string]$queued.createdAt
                        logCursor = 0L
                    }
                    Add-Audit -Remote $request.RemoteEndPoint.Address.ToString() -Action "player-password" -Detail "server=$($profile.id) steamId=$steamId username=$username requestedBy=$($session.user.username)" -Result "queued"
                    [void](Add-ExecutionHistoryRecord -ServerId ([string]$profile.id) -Category "command" -Action "player-password" -Source "web" -Summary "修改玩家账号密码：$username" -Status "queued" -Message "密码修改命令已安全提交。" -RequestIds @($requestId))
                    Write-JsonResponse $context 202 @{ ok = $true; message = "账号 $username 的密码修改命令已提交。"; requestId = $requestId; command = "[redacted]" }
                }
                finally {
                    $password = $null
                    $passwordConfirm = $null
                    $quotedPassword = $null
                }
                continue
            }
            if ($request.HttpMethod -eq "DELETE" -and $path -eq "/api/player-admin") {
                Assert-PlayerDataPermission -Session $session
                $body = Get-RequestBody $request
                $profile = Get-ServerProfile -Id ([string]$body.serverId)
                $steamId = ([string]$body.steamId).Trim()
                if ([string]$body.confirm -cne "DELETE_PLAYER_DATA") { throw "删除玩家数据需要专用确认标记。" }
                if ([string]$body.confirmSteamId -cne $steamId) { throw "确认 SteamID 与目标不一致，已取消删除。" }
                $serverState = Get-ServerState -Profile $profile
                if ($serverState.alive) { throw "服务器仍在运行。必须先安全停服，确认 Java 已退出后才能删除玩家数据。" }
                $activeOperation = Get-ActiveLifecycleOperation -Profile $profile
                if ($activeOperation) { throw "服务器正在执行生命周期任务，完成后才能删除玩家数据。" }
                $snapshot = Invoke-PZPlayerDataManager -Profile $profile -Mode "inspect" -SteamId $steamId
                $deletable = @($snapshot.accounts).Count -gt 0 -or @($snapshot.characters).Count -gt 0 -or [bool]$snapshot.allowed
                if (-not $deletable) { throw "SteamID $steamId 没有可删除的账号、角色或允许列表数据。" }
                $backupPath = Backup-PZPlayerDatabases -Profile $profile -SteamId $steamId -Snapshot $snapshot
                $result = Invoke-PZPlayerDataManager -Profile $profile -Mode "delete" -SteamId $steamId
                $summary = "删除 SteamID $steamId：账号 $([int]$result.deletedAccounts)，角色 $([int]$result.deletedCharacters)，允许列表 $([int]$result.deletedAllowedEntries)"
                Add-Audit -Remote $request.RemoteEndPoint.Address.ToString() -Action "player-data-delete" -Detail "server=$($profile.id) steamId=$steamId accounts=$($result.deletedAccounts) characters=$($result.deletedCharacters) allowed=$($result.deletedAllowedEntries) backup=$backupPath requestedBy=$($session.user.username) banPreserved=$($result.banPreserved)" -Result "ok"
                [void](Add-ExecutionHistoryRecord -ServerId ([string]$profile.id) -Category "command" -Action "player-data-delete" -Source "web" -Summary $summary -Status "success" -Message "玩家账号和角色数据已删除；封禁记录与审计日志保留。" -Detail "备份目录：$backupPath")
                Write-JsonResponse $context 200 @{ ok = $true; message = "$summary。"; steamId = $steamId; deletedAccounts = [int]$result.deletedAccounts; deletedCharacters = [int]$result.deletedCharacters; deletedAllowedEntries = [int]$result.deletedAllowedEntries; banPreserved = [bool]$result.banPreserved; backupPath = $backupPath }
                continue
            }
            if ($request.HttpMethod -eq "GET" -and $path -eq "/api/players/export") {
                $profile = Get-ServerProfile -Id ([string]$request.QueryString["serverId"])
                $directory = Get-PlayerDirectory -Profile $profile
                $exportedAt = Get-Date
                $lines = [Collections.Generic.List[string]]::new()
                $headers = @("服务器配置ID", "PZ实例名", "玩家用户名", "SteamID64", "权限角色", "在线状态", "最近连接时间", "导出时间")
                $lines.Add((($headers | ForEach-Object { ConvertTo-CsvCell $_ }) -join ','))
                foreach ($player in @($directory.players)) {
                    $steamId = [string]$player.steamId
                    $excelSteamId = if ($steamId -match '^\d{17}$') { '="' + $steamId + '"' } else { $steamId }
                    $username = [string]$player.username
                    if ($username -match '^[=+\-@]') { $username = "'" + $username }
                    $row = @(
                        [string]$profile.id,
                        [string]$profile.serverName,
                        $username,
                        $excelSteamId,
                        [string]$player.role,
                        $(if ([bool]$player.online) { "在线" } else { "离线" }),
                        [string]$player.lastConnection,
                        $exportedAt.ToString("yyyy-MM-dd HH:mm:ss")
                    )
                    $lines.Add((($row | ForEach-Object { ConvertTo-CsvCell $_ }) -join ','))
                }
                $fileName = "PZ-players-$($profile.id)-$($exportedAt.ToString('yyyyMMdd-HHmmss')).csv"
                Add-Audit -Remote $request.RemoteEndPoint.Address.ToString() -Action "player-export" -Detail "server=$($profile.id) count=$(@($directory.players).Count) requestedBy=$($session.user.username)" -Result "ok"
                Write-CsvDownload -Context $context -FileName $fileName -Lines $lines
                continue
            }
            if ($request.HttpMethod -eq "GET" -and $path -eq "/api/system") {
                $metrics = [pscustomobject](Get-SystemMetricsPayload)
                $metrics | Add-Member -NotePropertyName "hostControl" -NotePropertyValue (Get-HostControlStatus -Session $session) -Force
                Write-JsonResponse $context 200 $metrics
                continue
            }
            if ($request.HttpMethod -eq "POST" -and $path -eq "/api/host/startup-task") {
                Assert-HostControlAdministrator -Session $session
                $body = Get-RequestBody $request
                if ([string]$body.confirm -cne "CHANGE_HOST_STARTUP") { throw "修改开机任务需要二次确认。" }
                $enabled = [bool]$body.enabled
                $taskResult = Set-HostStartupTask -Enabled $enabled
                Add-Audit -Remote $request.RemoteEndPoint.Address.ToString() -Action "host-startup-task" -Detail "enabled=$enabled requestedBy=$($session.user.username)" -Result "ok"
                Write-JsonResponse $context 200 @{
                    ok = $true
                    message = if ($enabled) { "Web 面板开机启动任务已启用；下次开机会在登录桌面前启动。" } else { "Web 面板开机启动任务已移除。" }
                    task = $taskResult
                }
                continue
            }
            if ($request.HttpMethod -eq "GET" -and $path -eq "/api/host/autologon/launcher") {
                Assert-HostControlAdministrator -Session $session
                if (-not (Test-LocalRequest $request)) { throw "自动进入桌面配置脚本只能从服务器本机页面下载。" }
                if (-not (Test-Path -LiteralPath $hostAutoLogonScript -PathType Leaf) -or
                        -not (Test-Path -LiteralPath $hostAutoLogonLauncherPath -PathType Leaf)) { throw "缺少自动登录配置脚本。" }
                $bytes = [IO.File]::ReadAllBytes($hostAutoLogonLauncherPath)
                $context.Response.StatusCode = 200
                $context.Response.ContentType = "application/octet-stream"
                $context.Response.AddHeader("Content-Disposition", "attachment; filename=Configure-PZPanelAutoLogon.bat")
                $context.Response.ContentLength64 = $bytes.Length
                $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $context.Response.Close()
                Add-Audit -Remote "local" -Action "host-autologon-tool" -Detail "requestedBy=$($session.user.username)" -Result "downloaded"
                continue
            }
            if ($request.HttpMethod -eq "POST" -and $path -eq "/api/host/restart") {
                Assert-HostControlAdministrator -Session $session
                $body = Get-RequestBody $request
                if ([string]$body.confirm -cne "RESTART_PHYSICAL_HOST") { throw "重启物理机需要输入指定确认文字。" }
                $executeAt = Start-HostRestartCountdown -RequestedBy ([string]$session.user.username) -Remote $request.RemoteEndPoint.Address.ToString()
                Write-JsonResponse $context 202 @{ ok = $true; message = "物理机将在 30 秒后重新启动。可在倒计时结束前点击取消。"; executeAt = $executeAt.ToString("o") }
                continue
            }
            if ($request.HttpMethod -eq "POST" -and $path -eq "/api/host/restart/cancel") {
                Assert-HostControlAdministrator -Session $session
                $body = Get-RequestBody $request
                if ([string]$body.confirm -cne "CANCEL_HOST_RESTART") { throw "取消物理机重启需要二次确认。" }
                Stop-HostRestartCountdown -RequestedBy ([string]$session.user.username) -Remote $request.RemoteEndPoint.Address.ToString()
                Write-JsonResponse $context 200 @{ ok = $true; message = "物理机重启倒计时已取消。" }
                continue
            }
            if ($request.HttpMethod -eq "GET" -and $path -eq "/api/items") {
                $profile = Get-ServerProfile -Id ([string]$request.QueryString["serverId"])
                $limit = 40
                if (-not [string]::IsNullOrWhiteSpace([string]$request.QueryString["limit"])) {
                    [void][int]::TryParse([string]$request.QueryString["limit"], [ref]$limit)
                }
                $limit = [math]::Max(1, [math]::Min(60, $limit))
                $payload = Get-ItemSearchPayload -Profile $profile -Query ([string](Get-Utf8QueryValue -Request $request -Name "q")) -Limit $limit
                Write-JsonResponse $context 200 (@{ ok = $true; serverId = [string]$profile.id } + $payload)
                continue
            }
            if ($request.HttpMethod -eq "GET" -and $path -eq "/api/items/catalog") {
                $profile = Get-ServerProfile -Id ([string]$request.QueryString["serverId"])
                $page = 1
                $pageSize = 60
                if ($request.QueryString["page"]) { [void][int]::TryParse([string]$request.QueryString["page"], [ref]$page) }
                if ($request.QueryString["pageSize"]) { [void][int]::TryParse([string]$request.QueryString["pageSize"], [ref]$pageSize) }
                $pageSize = [math]::Max(20, [math]::Min(100, $pageSize))
                $payload = Get-ItemCatalogPayload -Profile $profile `
                    -Query ([string](Get-Utf8QueryValue -Request $request -Name "q")) `
                    -Category ([string](Get-Utf8QueryValue -Request $request -Name "category")) `
                    -Source ([string]$request.QueryString["source"]) `
                    -ModId ([string](Get-Utf8QueryValue -Request $request -Name "mod")) `
                    -Page $page -PageSize $pageSize
                Write-JsonResponse $context 200 (@{ ok = $true; serverId = [string]$profile.id } + $payload)
                continue
            }
            if ($request.HttpMethod -eq "GET" -and $path -eq "/api/items/status") {
                $profile = Get-ServerProfile -Id ([string]$request.QueryString["serverId"])
                $payload = Get-ItemIndexStatusPayload -Profile $profile
                if (-not $payload.cacheAvailable -and -not $payload.building -and -not $payload.error) {
                    [void](Start-ItemIndexBuild -Profile $profile)
                    $payload = Get-ItemIndexStatusPayload -Profile $profile
                }
                Write-JsonResponse $context 200 (@{ ok = $true; serverId = [string]$profile.id } + $payload)
                continue
            }
            if ($request.HttpMethod -eq "POST" -and $path -eq "/api/items/rebuild") {
                $body = Get-RequestBody $request
                $profile = Get-ServerProfile -Id ([string]$body.serverId)
                $status = Start-ItemIndexBuild -Profile $profile -Force
                Add-Audit -Remote $request.RemoteEndPoint.Address.ToString() -Action "item-index-rebuild" -Detail "server=$($profile.id)" -Result "ok"
                Write-JsonResponse $context 202 @{ ok = $true; message = "已在后台重新扫描 $($profile.name) 的本体和启用 Mod 物品。"; building = $true }
                continue
            }
            if ($request.HttpMethod -eq "GET" -and $path -eq "/api/audit") {
                $auditText = Read-Utf8Tail -Path $auditPath -MaxBytes 65536
                $lines = if ([string]::IsNullOrWhiteSpace($auditText)) { @() } else { @($auditText -split "`r?`n" | Where-Object { $_ }) }
                if ($lines.Count -gt 100) { $lines = @($lines[($lines.Count - 100)..($lines.Count - 1)]) }
                Write-JsonResponse $context 200 @{ ok = $true; lines = $lines }
                continue
            }
            if ($request.HttpMethod -eq "POST" -and $path -eq "/api/command") {
                $body = Get-RequestBody $request
                $profile = Get-ServerProfile -Id ([string]$body.serverId)
                if ([string]$body.action -eq "user-account") { Assert-PlayerDataPermission -Session $session }
                $clientRequestId = ([string]$body.submissionId).ToLowerInvariant()
                if (-not [string]::IsNullOrWhiteSpace($clientRequestId) -and $clientRequestId -notmatch '^[a-f0-9]{32}$') { throw "命令提交 ID 无效。" }
                if ([string]$body.action -eq 'additem' -and -not [string]::IsNullOrWhiteSpace($clientRequestId)) {
                    $existingSubmission = Get-CommandSubmissionPayload -Profile $profile -Id $clientRequestId
                    if ($existingSubmission.found) {
                        Add-Audit -Remote $request.RemoteEndPoint.Address.ToString() -Action "additem-duplicate" -Detail "server=$($profile.id) submission=$clientRequestId" -Result "recovered"
                        $existingSubmission['message'] = "检测到相同的物品发放提交，已返回原任务状态，没有重复发放。"
                        $existingSubmission['notificationWarnings'] = @()
                        Write-JsonResponse $context 200 $existingSubmission
                        continue
                    }
                }
                if ([string]$body.action -eq "worldgen" -and [string]$body.mode -in @("start", "recheck")) {
                    $serverState = Get-ServerState -Profile $profile
                    if ($serverState.onlineKnown -and [int]$serverState.onlineCount -gt 0) {
                        throw "当前有 $($serverState.onlineCount) 名玩家在线，禁止启动世界生成。请在所有玩家离线后再操作。"
                    }
                }
                $addItemBatch = $null
                $itemNotificationChannel = "none"
                $commands = @(
                    if ([string]$body.action -eq "broadcast") { Get-BroadcastCommands -Message ([string]$body.message) }
                    elseif ([string]$body.action -eq "additem") {
                        $addItemBatch = Resolve-AddItemBatch -Profile $profile -Body $body
                        $itemNotificationChannel = ([string]$body.notificationChannel).ToLowerInvariant()
                        if ([string]::IsNullOrWhiteSpace($itemNotificationChannel)) { $itemNotificationChannel = "none" }
                        if ($itemNotificationChannel -notin @("none", "native", "popup", "both")) { throw "物品发放通知通道无效。" }
                        $addItemBatch.commands
                    }
                    else { Resolve-Command $body }
                )
                $logCursor = 0L
                if ($profile.consoleLog -and (Test-Path -LiteralPath ([string]$profile.consoleLog))) {
                    $logCursor = (Get-Item -LiteralPath ([string]$profile.consoleLog)).Length
                }
                $queued = @()
                foreach ($command in $commands) {
                    $queued += Queue-Command -Profile $profile -Command $command -RequireReceipt:$true
                }
                $requestIds = @()
                for ($index = 0; $index -lt $queued.Count; $index += 1) {
                    $requestId = [string]$queued[$index].id
                    $requestIds += $requestId
                    $trackedCommand = if ([string]$body.action -eq "user-account" -and -not [string]::IsNullOrWhiteSpace([string]$body.password)) { "[redacted]" } else { [string]$commands[$index] }
                    $commandRequests[$requestId] = [pscustomobject]@{
                        serverId = [string]$profile.id
                        action = [string]$body.action
                        command = $trackedCommand
                        queuedAt = [string]$queued[$index].createdAt
                        logCursor = $logCursor
                    }
                }
                foreach ($key in @($commandRequests.Keys)) {
                    if (((Get-Date) - [datetime]$commandRequests[$key].queuedAt).TotalHours -gt 2) { $commandRequests.Remove($key) }
                }
                $itemRequestIds = @($requestIds)
                $itemNotification = $null
                if ($addItemBatch) {
                    $itemNotification = Invoke-ItemGrantNotification -Profile $profile -Body $body -TargetCount ([int]$addItemBatch.targets.Count) -LogCursor $logCursor
                }
                $notificationRequestIds = if ($itemNotification) { @($itemNotification.requestIds) } else { @() }
                $allRequestIds = @($itemRequestIds) + @($notificationRequestIds)
                $noticeId = if ($itemNotification) { [string]$itemNotification.noticeId } else { "" }
                $notificationWarnings = if ($itemNotification) { @($itemNotification.warnings) } else { @() }
                $remote = $request.RemoteEndPoint.Address.ToString()
                $detail = switch ([string]$body.action) {
                    "broadcast" { "server=$($profile.id) messageLength=$(([string]$body.message).Length) parts=$($commands.Count)" }
                    "additem" { "server=$($profile.id) item=$($body.item) count=$([int]$body.count) targets=$($addItemBatch.targets.Count) notification=$itemNotificationChannel" }
                    "user-account" { "server=$($profile.id) accountAction=$($body.mode) username=$($body.username)" }
                    "change-option" { "server=$($profile.id) optionName=$($body.name) value=redacted" }
                    default { "server=$($profile.id) command=$($commands[0])" }
                }
                Add-Audit -Remote $remote -Action ([string]$body.action) -Detail $detail
                $message = if ([string]$body.action -eq "broadcast" -and $commands.Count -gt 1) {
                    "广播已自动拆成 $($commands.Count) 条并进入 $($profile.name) 队列。"
                } elseif ([string]$body.action -eq "additem") {
                    $noticeSummary = if ($itemNotificationChannel -eq "none") { "" } elseif ($notificationWarnings.Count) { "；附加通知存在警告：$($notificationWarnings -join '；')" } else { "；已同时提交 $(@($itemNotification.channels) -join ' + ')" }
                    "物品发放已为 $($addItemBatch.targets.Count) 名在线玩家进入 $($profile.name) 队列$noticeSummary。"
                } else { "命令已进入 $($profile.name) 队列。" }
                $targetCount = if ($addItemBatch) { [int]$addItemBatch.targets.Count } else { 0 }
                $historyCategory = if ([string]$body.action -eq "additem") { "item" } elseif ([string]$body.action -eq "broadcast") { "broadcast" } elseif ([string]$body.action -in @("players", "connections", "stats", "showoptions", "help", "help-topic", "worldgen-status")) { "query" } elseif ([string]$body.action -eq "check-mod-updates") { "update" } else { "command" }
                $historySummary = if ([string]$body.action -eq "additem") {
                    "发放 $([string]$body.item) x$([int]$body.count)，目标 $targetCount 人"
                } elseif ([string]$body.action -eq "broadcast") {
                    "发送全服广播，共 $($commands.Count) 段"
                } else { "$(if ($body.action) { [string]$body.action } else { '服务器命令' })" }
                [void](Add-ExecutionHistoryRecord -ServerId ([string]$profile.id) -Category $historyCategory -Action ([string]$body.action) `
                    -Source "web" -Summary $historySummary -Status $(if ($notificationWarnings.Count) { "warning" } else { "queued" }) -Message $message `
                    -RequestIds $itemRequestIds -AuxiliaryRequestIds $notificationRequestIds -NoticeId $noticeId -Detail $(if ($itemNotification -and $itemNotification.message) { [string]$itemNotification.message } else { "" }) `
                    -ClientRequestId $clientRequestId)
                $immediateItemResult = $null
                if ($addItemBatch -and -not [string]::IsNullOrWhiteSpace($clientRequestId)) {
                    $immediateItemResult = Wait-ItemGrantSubmissionResult -Profile $profile -SubmissionId $clientRequestId -RequestIds $itemRequestIds -TimeoutMilliseconds 5000
                }
                $responseCommand = if ([string]$body.action -eq "user-account" -and -not [string]::IsNullOrWhiteSpace([string]$body.password)) { "[redacted]" } else { [string]$commands[0] }
                $publicRequestIds = if ($immediateItemResult -and $immediateItemResult.settled -and $targetCount -eq 1) { @() } else { $itemRequestIds }
                Write-JsonResponse $context 202 @{ ok = $true; message = $message; submissionId = $clientRequestId; requestId = [string]$itemRequestIds[0]; requestIds = $publicRequestIds; itemRequestIds = $itemRequestIds; notificationRequestIds = $notificationRequestIds; allRequestIds = $allRequestIds; noticeId = $noticeId; notificationChannel = $itemNotificationChannel; notificationWarnings = $notificationWarnings; expectedNoticeClients = $(if ($itemNotification) { [int]$itemNotification.expectedClients } else { 0 }); command = $responseCommand; parts = $commands.Count; targetCount = $targetCount; immediateItemResult = $immediateItemResult }
                continue
            }
            if ($request.HttpMethod -eq "POST" -and $path -eq "/api/server/start") {
                $body = Get-RequestBody $request
                $profile = Get-ServerProfile -Id ([string]$body.serverId)
                $adminPassword = [string]$body.adminPassword
                $adminPasswordConfirm = [string]$body.adminPasswordConfirm
                $hasAdminPassword = $null -ne $body.PSObject.Properties["adminPassword"]
                $hasAdminPasswordConfirm = $null -ne $body.PSObject.Properties["adminPasswordConfirm"]
                $secretPath = $null
                $activeOperation = Get-ActiveLifecycleOperation -Profile $profile
                if ($activeOperation) { throw "当前正在执行服务器生命周期操作，完成前不能另行启动：$($activeOperation.message)" }
                if (-not $profile.startScript) { throw "服务器 $($profile.name) 没有配置受控启动脚本。" }
                $serverState = Get-ServerState -Profile $profile
                if (-not $serverState.canStart) { throw $serverState.startReason }
                if ([bool]$serverState.adminSetupRequired) {
                    if (-not $hasAdminPassword -or -not $hasAdminPasswordConfirm) {
                        throw "首次设置游戏内置 admin 密码时，必须完整输入并确认两次密码。"
                    }
                    if (-not [string]::Equals($adminPassword, $adminPasswordConfirm, [StringComparison]::Ordinal)) {
                        throw "两次输入的游戏内置 admin 密码不一致，服务器没有启动。"
                    }
                    $adminPassword = Assert-PZInitialAdminPassword -Password $adminPassword
                    $secretPath = New-ProtectedAdminLaunchSecret -Profile $profile -Password $adminPassword
                }
                elseif ($hasAdminPassword -or $hasAdminPasswordConfirm) {
                    throw "游戏账号数据库已经存在，不接受首次 admin 初始化密码。"
                }
                $launchStartedAt = Get-Date
                $windowStyle = if ([bool]$profile.showConsole) { "Normal" } else { "Hidden" }
                try {
                    $launchArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$($profile.startScript)`""
                    if ($secretPath) { $launchArguments += " -AdminPasswordSecretPath `"$secretPath`"" }
                    $launchProcess = Start-Process -FilePath "powershell.exe" -ArgumentList $launchArguments -WindowStyle $windowStyle -PassThru
                }
                catch {
                    if ($secretPath) { Remove-Item -LiteralPath $secretPath -Force -ErrorAction SilentlyContinue }
                    throw
                }
                finally {
                    $adminPassword = $null
                    $adminPasswordConfirm = $null
                }
                $managedPaths = Get-ManagedProfilePaths -Id ([string]$profile.id)
                $launchDeadline = (Get-Date).AddSeconds(8)
                $launchRunningSince = $null
                $launchAccepted = $false
                do {
                    Start-Sleep -Milliseconds 200
                    $launchState = $null
                    if (Test-Path -LiteralPath $managedPaths.statePath) {
                        try { $launchState = Get-Content -LiteralPath $managedPaths.statePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
                    }
                    $stateIsCurrent = $launchState -and $launchState.updatedAt -and ([datetime]$launchState.updatedAt) -ge $launchStartedAt.AddSeconds(-1)
                    if ($stateIsCurrent -and [string]$launchState.status -eq "running") {
                        if (-not $launchRunningSince) { $launchRunningSince = Get-Date }
                        if (((Get-Date) - $launchRunningSince).TotalSeconds -ge 2) { $launchAccepted = $true; break }
                    }
                    else {
                        $launchRunningSince = $null
                        if ($stateIsCurrent -and [string]$launchState.status -in @("waiting-startup-lock", "starting") -and -not $launchProcess.HasExited) {
                            $launchAccepted = $true
                        }
                    }
                    if ($stateIsCurrent -and [string]$launchState.status -in @("failed", "stopped")) {
                        $failure = if ($launchState.failure) { [string]$launchState.failure } elseif ($null -ne $launchState.exitCode) { "Java 进程已退出，退出码 $($launchState.exitCode)。" } else { "Java 进程在进入运行状态前退出。" }
                        throw "服务器启动失败：$failure"
                    }
                    if ($launchProcess.HasExited) {
                        $failure = if ($stateIsCurrent -and $launchState.failure) { [string]$launchState.failure } else { "启动脚本已退出，退出码 $($launchProcess.ExitCode)。" }
                        throw "服务器启动失败：$failure"
                    }
                } while ((Get-Date) -lt $launchDeadline)
                if (-not $launchAccepted) {
                    throw "服务器启动失败：托管启动器未在 8 秒内进入启动流程。"
                }
                $script:statusCache = $null
                $script:statusCacheAt = [datetime]::MinValue
                $script:pzProcessInfoCacheAt = [datetime]::MinValue
                $initialSetup = [bool]$serverState.adminSetupRequired
                Add-Audit -Remote $request.RemoteEndPoint.Address.ToString() -Action "server-start" -Detail "server=$($profile.id) adminInitialized=$initialSetup"
                [void](Add-ExecutionHistoryRecord -ServerId ([string]$profile.id) -Category "lifecycle" -Action "start" -Source "web" `
                    -Summary $(if ($initialSetup) { "初始化 admin 并启动服务器" } else { "启动服务器" }) -Status "running" `
                    -Message $(if ($initialSetup) { "一次性 admin 初始化参数已安全交给启动器，正在等待服务器创建账号数据库。" } else { "启动脚本已接收，正在等待服务器进入运行状态。" }))
                Write-JsonResponse $context 202 @{ ok = $true; message = $(if ($initialSetup) { "首次启动命令已接收，正在创建游戏账号数据库。" } else { "启动命令已接收，正在等待服务器进入运行状态。" }) }
                continue
            }
            if ($request.HttpMethod -eq "POST" -and $path -eq "/api/server/stop") {
                $body = Get-RequestBody $request
                $profile = Get-ServerProfile -Id ([string]$body.serverId)
                if ($body.confirm -ne "SAVE_AND_STOP") { throw "停止服务器需要二次确认。" }
                if (-not $profile.stopScript) { throw "服务器 $($profile.name) 没有配置受控停止脚本。" }
                $serverState = Get-ServerState -Profile $profile
                if (-not $serverState.writable) { throw $serverState.note }
                $operationId = Start-LifecycleOperation -Profile $profile -Action "stop"
                $script:statusCache = $null
                $script:statusCacheAt = [datetime]::MinValue
                Add-Audit -Remote $request.RemoteEndPoint.Address.ToString() -Action "server-stop" -Detail "server=$($profile.id) save then quit"
                [void](Add-ExecutionHistoryRecord -ServerId ([string]$profile.id) -Category "lifecycle" -Action "stop" -Source "web" `
                    -Summary "保存并停止服务器" -Status "queued" -Message "正在保存，完成后将正常退出。" -OperationId $operationId)
                Write-JsonResponse $context 202 @{ ok = $true; message = "正在保存，完成后将正常退出。"; operationId = $operationId }
                continue
            }
            if ($request.HttpMethod -eq "POST" -and $path -eq "/api/server/restart") {
                $body = Get-RequestBody $request
                $profile = Get-ServerProfile -Id ([string]$body.serverId)
                if ($body.confirm -ne "SAVE_QUIT_RESTART") { throw "重启服务器需要二次确认。" }
                $serverState = Get-ServerState -Profile $profile
                if (-not $serverState.canRestart) { throw "服务器尚未由面板受控启动，当前不能执行安全重启。" }
                if ([bool]$serverState.adminSetupRequired) { throw "游戏账号数据库已缺失，不能执行安全重启。请先停止服务器，再点击启动按钮设置一次游戏内置 admin 密码。" }
                $warningSeconds = [int]$body.warningSeconds
                if ($warningSeconds -eq 0) { $warningSeconds = 60 }
                if ($warningSeconds -lt 10 -or $warningSeconds -gt 600) { throw "重启通知倒计时必须为 10 至 600 秒。" }
                $schedule = Get-MaintenanceSchedule -ServerId ([string]$profile.id)
                $restartStabilizationSeconds = if ($null -ne $body.restartStabilizationSeconds) { [int]$body.restartStabilizationSeconds } else { [int]$schedule.restartStabilizationSeconds }
                if ($restartStabilizationSeconds -lt 10 -or $restartStabilizationSeconds -gt 600) { throw "停服后启动缓冲必须为 10 至 600 秒。" }
                $operationId = Start-LifecycleOperation -Profile $profile -Action "restart" -WarningSeconds $warningSeconds -RestartStabilizationSeconds $restartStabilizationSeconds
                $script:statusCache = $null
                $script:statusCacheAt = [datetime]::MinValue
                Add-Audit -Remote $request.RemoteEndPoint.Address.ToString() -Action "server-restart" -Detail "server=$($profile.id) warningSeconds=$warningSeconds stabilizationSeconds=$restartStabilizationSeconds notify then save receipt then quit then stabilize then start"
                [void](Add-ExecutionHistoryRecord -ServerId ([string]$profile.id) -Category "lifecycle" -Action "restart" -Source "web" `
                    -Summary "安全重启服务器（通知 $warningSeconds 秒，停服缓冲 $restartStabilizationSeconds 秒）" -Status "queued" -Message "正在通知玩家，随后将保存、退出，旧 Java 完全结束后缓冲 $restartStabilizationSeconds 秒再启动。" -OperationId $operationId)
                Write-JsonResponse $context 202 @{ ok = $true; message = "正在发送双通道维护通知；倒计时结束后将保存、退出，停服后缓冲 $restartStabilizationSeconds 秒再启动。"; operationId = $operationId }
                continue
            }
            Write-JsonResponse $context 404 @{ ok = $false; error = "接口不存在。" }
        }
        catch {
            try { Write-JsonResponse $context 400 @{ ok = $false; error = $_.Exception.Message } } catch { }
        }
        finally {
            try {
                [IO.File]::WriteAllText($requestStatePath, ([ordered]@{
                    status = "completed"
                    method = if ($request) { [string]$request.HttpMethod } else { $null }
                    path = if ($request) { [string]$request.RawUrl } else { $null }
                    completedAt = (Get-Date).ToString("o")
                    durationMs = [math]::Round(((Get-Date) - $requestStartedAt).TotalMilliseconds)
                } | ConvertTo-Json), $utf8)
            } catch { }
            try { $context.Response.OutputStream.Close() } catch { }
            try { $context.Response.Close() } catch { }
        }
    }
}
finally {
    Stop-AIBridge
    Add-Audit -Remote "local" -Action "panel-stop" -Detail "listener stopped" -Result "ok"
    $listener.Stop()
    $listener.Close()
    Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $requestStatePath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stopRequestPath -Force -ErrorAction SilentlyContinue
}
