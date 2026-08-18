param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("stop", "restart", "update")]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-f0-9]{32}$')]
    [string]$OperationId,

    [Parameter(Mandatory = $true)]
    [string]$ProfilePath,

    [ValidateRange(0, 600)]
    [int]$WarningSeconds = 60,

    [ValidateRange(10, 600)]
    [int]$RestartStabilizationSeconds = 60,

    [ValidateSet("manual", "mod-update")]
    [string]$Trigger = "manual",

    [string]$SteamCmdPath = "",

    [string]$InstallDirectory = "",

    [ValidateSet("steam-library", "force-install-dir")]
    [string]$InstallMode = "force-install-dir",

    [string]$ManifestPath = "",

    [ValidatePattern('^$|^\d+$')]
    [string]$RemoteBuildId = ""
)

$ErrorActionPreference = "Stop"
$utf8 = [Text.UTF8Encoding]::new($false)
$controlRoot = Split-Path -Parent $ProfilePath
$queueDir = Join-Path $controlRoot "commands"
$receiptDir = Join-Path $controlRoot "receipts"
$statePath = Join-Path $controlRoot "state.json"
$operationPath = Join-Path $controlRoot "lifecycle-operation.json"
$lockPath = Join-Path $controlRoot "lifecycle.lock"
$startScript = Join-Path $controlRoot "Start-ManagedPZ.ps1"
$profile = Get-Content -LiteralPath $ProfilePath -Raw -Encoding UTF8 | ConvertFrom-Json
$operationStartedAt = Get-Date
$oldJavaPid = $null
$newJavaPid = $null
$lockStream = $null
$steamLockStream = $null
$operationWarnings = @()
$countdownUntil = $null
$stabilizationUntil = $null
$operationDetail = ""
$serverWasRunning = $false

function Write-Operation {
    param(
        [string]$Status,
        [string]$Stage,
        [string]$Message,
        [AllowNull()][string]$ErrorMessage = $null
    )
    $operation = [ordered]@{
        id = $OperationId
        action = $Action
        trigger = $Trigger
        serverId = [string]$profile.id
        status = $Status
        stage = $Stage
        message = $Message
        startedAt = $operationStartedAt.ToString("o")
        updatedAt = (Get-Date).ToString("o")
        oldJavaPid = $oldJavaPid
        newJavaPid = $newJavaPid
        warningSeconds = if ($Action -in @("restart", "update")) { $WarningSeconds } else { 0 }
        countdownUntil = $countdownUntil
        restartStabilizationSeconds = if ($Action -in @("restart", "update")) { $RestartStabilizationSeconds } else { 0 }
        stabilizationUntil = $stabilizationUntil
        targetBuildId = if ($Action -eq "update") { $RemoteBuildId } else { $null }
        installDirectory = if ($Action -eq "update") { $InstallDirectory } else { $null }
        installMode = if ($Action -eq "update") { $InstallMode } else { $null }
        manifestPath = if ($Action -eq "update") { $ManifestPath } else { $null }
        warnings = @($operationWarnings)
        detail = $operationDetail
        error = $ErrorMessage
    }
    $tempPath = "$operationPath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($tempPath, ($operation | ConvertTo-Json -Depth 4), $utf8)
        Move-Item -LiteralPath $tempPath -Destination $operationPath -Force
    }
    finally { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
}

function Read-State {
    if (-not (Test-Path -LiteralPath $statePath)) { return $null }
    try { return Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { return $null }
}

function Submit-Command {
    param([string]$Command, [int]$TimeoutSeconds)
    $id = [guid]::NewGuid().ToString("N")
    $request = [ordered]@{ id = $id; createdAt = (Get-Date).ToString("o"); command = $Command; requireReceipt = $true }
    $name = "{0}-{1}.json" -f $request.createdAt.Replace(':','').Replace('.',''), $request.id
    [IO.File]::WriteAllText((Join-Path $queueDir $name), ($request | ConvertTo-Json -Compress), $utf8)
    $receiptPath = Join-Path $receiptDir "$id.json"
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $receiptPath) {
            try {
                $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ([string]$receipt.status -eq "completed") { return $receipt }
                if ([string]$receipt.status -eq "failed") { throw "Managed command failed: $Command - $($receipt.error)" }
            }
            catch { if ($_.Exception.Message -like "Managed command failed: $Command*") { throw } }
        }
        Start-Sleep -Milliseconds 250
    }
    throw "Timed out waiting for managed command receipt: $Command"
}

function ConvertTo-NoticeQueueText {
    param([string]$Value)
    return ([string]$Value).Replace('%', '%25').Replace("`t", '%09').Replace("`r", '%0D').Replace("`n", '%0A')
}

function Wait-PopupQueueUnlocked {
    param([string]$LuaRoot, [int]$TimeoutSeconds = 12)
    $lockPath = Join-Path $LuaRoot "PZWebNotices-queue.lock"
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (Test-Path -LiteralPath $lockPath -PathType Leaf) {
        $values = @{}
        try {
            foreach ($lockLine in Get-Content -LiteralPath $lockPath -Encoding UTF8 -ErrorAction Stop) {
                if ($lockLine -match '^(?<name>[A-Za-z][A-Za-z0-9]*)=(?<value>.*)$') { $values[$matches.name] = $matches.value }
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

function Send-NativeMaintenanceBroadcast {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message) -or $Message.Contains('"') -or $Message -match "[\r\n]") {
        throw "The maintenance broadcast text is invalid."
    }
    [void](Submit-Command -Command "servermsg `"$Message`"" -TimeoutSeconds 20)
}

function Send-PopupMaintenanceNotice {
    param([string]$Title, [string]$Message)
    $luaRoot = Join-Path ([string]$profile.dataRoot) "Lua"
    $heartbeatPath = Join-Path $luaRoot "PZWebNotices-heartbeat.ini"
    if (-not (Test-Path -LiteralPath $heartbeatPath -PathType Leaf)) { throw "PZWebNotices heartbeat is missing." }
    $heartbeat = @{}
    foreach ($line in Get-Content -LiteralPath $heartbeatPath -Encoding UTF8) {
        if ($line -match '^(?<name>[A-Za-z][A-Za-z0-9]*)=(?<value>.*)$') { $heartbeat[$matches.name] = $matches.value }
    }
    $updatedMs = 0L
    if (-not [long]::TryParse([string]$heartbeat.updatedMs, [ref]$updatedMs) -or $updatedMs -le 0) { throw "PZWebNotices heartbeat has no timestamp." }
    $ageSeconds = ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $updatedMs) / 1000
    if ($ageSeconds -gt 300) { throw "PZWebNotices heartbeat is older than 5 minutes." }
    try { $noticeVersion = [version]([string]$heartbeat.version) }
    catch { throw "PZWebNotices heartbeat has an invalid version." }
    if ($noticeVersion -lt [version]"0.2.3") { throw "PZWebNotices 0.2.3 or newer is required." }
    $expectedClients = 0
    if ($heartbeat.ContainsKey("online")) { [void][int]::TryParse([string]$heartbeat.online, [ref]$expectedClients) }
    [IO.Directory]::CreateDirectory($luaRoot) | Out-Null
    Wait-PopupQueueUnlocked -LuaRoot $luaRoot
    $id = "notice-" + [guid]::NewGuid().ToString("N")
    $line = @(
        "v3", $id, "all", "", "warning", "15", "medium", "medium", "#E3A846", "-",
        (ConvertTo-NoticeQueueText -Value $Title), (ConvertTo-NoticeQueueText -Value $Message), [string]$expectedClients
    ) -join "`t"
    $queuePath = Join-Path $luaRoot "PZWebNotices-queue.txt"
    $stream = [IO.File]::Open($queuePath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        $bytes = $utf8.GetBytes($line + "`n")
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
}

function Send-RestartWarning {
    $maintenanceAction = if ($Action -eq "update") { "更新并重启" } else { "安全重启" }
    $title = if ($Trigger -eq "mod-update") { "Mod 更新维护" } else { "服务器维护" }
    $message = if ($Trigger -eq "mod-update") {
        "检测到 Mod 有新版本，服务器将在 $WarningSeconds 秒后安全重启，请尽快停止操作并前往安全区域。"
    } else {
        "服务器将在 $WarningSeconds 秒后$maintenanceAction，请尽快停止操作并前往安全区域。"
    }
    $delivered = 0
    try {
        Send-NativeMaintenanceBroadcast -Message $message
        $delivered += 1
    }
    catch { $script:operationWarnings += "原生广播失败：$($_.Exception.Message)" }
    try {
        Send-PopupMaintenanceNotice -Title $title -Message $message
        $delivered += 1
    }
    catch { $script:operationWarnings += "右下角弹窗失败：$($_.Exception.Message)" }
    if ($delivered -eq 0) { throw "Both maintenance notification channels failed; restart was cancelled. $($operationWarnings -join ' ')" }
}

New-Item -ItemType Directory -Path $queueDir, $receiptDir -Force | Out-Null
try {
    $initialState = Read-State
    if ($initialState -and $initialState.javaPid) { $oldJavaPid = [int]$initialState.javaPid }
    if ($oldJavaPid) {
        $serverWasRunning = [bool](Get-Process -Id $oldJavaPid -ErrorAction SilentlyContinue)
        if (-not $serverWasRunning) { $oldJavaPid = $null }
    }
    Write-Operation -Status "running" -Stage "locking" -Message "正在取得服务器生命周期操作锁。"
    try {
        $lockStream = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    }
    catch { throw "已有另一个服务器生命周期操作正在运行。" }

    if ($Action -eq "update") {
        if (-not (Test-Path -LiteralPath $SteamCmdPath -PathType Leaf)) { throw "找不到 SteamCMD：$SteamCmdPath" }
        $steamLockPath = Join-Path (Split-Path -Parent $SteamCmdPath) "pz-app-380870-update.lock"
        try { $steamLockStream = [IO.File]::Open($steamLockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch { throw "另一个 PZ 服务器程序更新正在使用 SteamCMD，本服务器尚未停服，请等待其完成后重试。" }
    }

    if ($Action -in @("restart", "update")) {
        $adminDatabasePath = Join-Path ([string]$profile.dataRoot) "db\$([string]$profile.serverName).db"
        if (-not (Test-Path -LiteralPath $adminDatabasePath -PathType Leaf)) {
            throw "游戏账号数据库已缺失，安全重启已取消。请先停止服务器，再从面板手动启动并设置一次游戏内置 admin 密码。"
        }
        if ($serverWasRunning) {
            Write-Operation -Status "running" -Stage "notifying" -Message "正在发送原生广播和右下角维护通知。"
            Send-RestartWarning
            $countdownUntil = (Get-Date).AddSeconds($WarningSeconds).ToString("o")
            $warningSuffix = if ($operationWarnings.Count -gt 0) { " 部分通知通道不可用，已使用可用通道继续。" } else { "" }
            Write-Operation -Status "running" -Stage "countdown" -Message "维护通知已发送，等待 $WarningSeconds 秒后开始维护。$warningSuffix"
            Start-Sleep -Seconds $WarningSeconds
            $countdownUntil = $null
        }
    }

    if ($serverWasRunning) {
        Write-Operation -Status "running" -Stage "saving" -Message "正在保存世界，并等待受控命令通道确认。"
        [void](Submit-Command -Command "save" -TimeoutSeconds 45)

        if ($Action -in @("restart", "update") -and -not (Test-Path -LiteralPath $adminDatabasePath -PathType Leaf)) {
            throw "保存后检测到游戏账号数据库缺失；为避免退出后卡在首次密码输入，维护已在 quit 前取消。"
        }

        Write-Operation -Status "running" -Stage "quitting" -Message "保存已确认，正在请求服务器正常退出。"
        [void](Submit-Command -Command "quit" -TimeoutSeconds 20)

        Write-Operation -Status "running" -Stage "waiting-stop" -Message "退出命令已送达，正在等待旧 Java 进程完全结束。"
        $stopDeadline = (Get-Date).AddMinutes(3)
        $stopped = $false
        do {
            Start-Sleep -Milliseconds 500
            $state = Read-State
            $oldProcessAlive = $oldJavaPid -and [bool](Get-Process -Id $oldJavaPid -ErrorAction SilentlyContinue)
            if ($state -and [string]$state.status -in @("stopped", "failed") -and -not $state.javaPid -and -not $oldProcessAlive) {
                $stopped = $true
                break
            }
        } while ((Get-Date) -lt $stopDeadline)
        if (-not $stopped) { throw "执行 quit 后 Java 未在 3 分钟内结束；为避免更新运行中的文件，操作已中止。" }
    }

    if ($Action -eq "stop") {
        Write-Operation -Status "completed" -Stage "completed" -Message "世界已保存，服务器已正常停止。"
        exit 0
    }

    if ($serverWasRunning) {
        if ($oldJavaPid -and (Get-Process -Id $oldJavaPid -ErrorAction SilentlyContinue)) {
            throw "旧 Java PID $oldJavaPid 仍然存在，已取消启动新实例。"
        }
        $stabilizationUntil = (Get-Date).AddSeconds($RestartStabilizationSeconds).ToString("o")
        Write-Operation -Status "running" -Stage "stabilizing" -Message "旧 Java 已结束，正在等待 $RestartStabilizationSeconds 秒释放大内存、端口和 Steam 网络资源。"
        Start-Sleep -Seconds $RestartStabilizationSeconds
        $stabilizationUntil = $null
        if ($oldJavaPid -and (Get-Process -Id $oldJavaPid -ErrorAction SilentlyContinue)) {
            throw "资源释放缓冲结束后旧 Java PID $oldJavaPid 再次出现，已取消启动新实例。"
        }
    }

    if ($Action -eq "update") {
        if ([string]::IsNullOrWhiteSpace($InstallDirectory) -or -not (Test-Path -LiteralPath $InstallDirectory -PathType Container)) {
            throw "服务器运行目录不存在：$InstallDirectory"
        }
        Write-Operation -Status "running" -Stage "updating" -Message "正在通过 SteamCMD 更新 AppID 380870 的 public 分支，请勿关闭面板。"
        $steamArguments = @()
        if ($InstallMode -eq "force-install-dir") {
            $steamArguments += @("+force_install_dir", $InstallDirectory)
        }
        $steamArguments += @("+login", "anonymous", "+app_update", "380870", "validate", "+quit")
        $steamOutput = @(& $SteamCmdPath @steamArguments 2>&1 | ForEach-Object { [string]$_ })
        $steamExitCode = $LASTEXITCODE
        $operationDetail = @($steamOutput | Select-Object -Last 120) -join "`n"
        Write-Operation -Status "running" -Stage "verifying-update" -Message "SteamCMD 已结束，正在核对安装结果。"
        if ($steamExitCode -ne 0) { throw "SteamCMD 更新失败，退出码 $steamExitCode。" }
        if (-not ($operationDetail -match "Success! App '380870' fully installed")) {
            throw "SteamCMD 没有返回完整安装成功标记，请查看执行详情。"
        }
        if ([string]::IsNullOrWhiteSpace($ManifestPath)) { throw "没有为本次更新指定安装清单路径。" }
        $installedBuildId = $null
        if (Test-Path -LiteralPath $ManifestPath -PathType Leaf) {
            $manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8
            if ($manifest -match '(?m)^\s*"buildid"\s+"(?<id>\d+)"\s*$') { $installedBuildId = [string]$matches.id }
        }
        if (-not $installedBuildId) {
            throw "SteamCMD 返回成功，但没有生成有效安装清单：$ManifestPath"
        }
        if ($RemoteBuildId -and $installedBuildId -cne $RemoteBuildId) {
            throw "更新后的 BuildID 为 $installedBuildId，与检查到的目标 $RemoteBuildId 不一致。"
        }
        $operationDetail += "`n`n安装模式：$InstallMode`n安装目录：$InstallDirectory`n安装清单：$ManifestPath`n目标 BuildID：$RemoteBuildId`n安装 BuildID：$installedBuildId"
        if ($steamLockStream) { $steamLockStream.Dispose(); $steamLockStream = $null }
    }

    Write-Operation -Status "running" -Stage "starting" -Message $(if ($Action -eq "update") { "程序更新完成，正在启动服务器。" } else { "旧 Java 进程已结束，正在启动新实例。" })
    $windowStyle = if ([bool]$profile.showConsole) { "Normal" } else { "Hidden" }
    $launchStartedAt = Get-Date
    $launchProcess = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$startScript`"" -WindowStyle $windowStyle -PassThru

    Write-Operation -Status "running" -Stage "waiting-running" -Message "启动脚本已执行，正在等待新 Java 进入运行状态。"
    $startDeadline = (Get-Date).AddMinutes(15)
    do {
        Start-Sleep -Milliseconds 500
        $state = Read-State
        $stateIsCurrent = $state -and $state.updatedAt -and ([datetime]$state.updatedAt) -ge $launchStartedAt.AddSeconds(-1)
        if ($stateIsCurrent -and [string]$state.status -eq "running" -and $state.javaPid -and [int]$state.javaPid -ne [int]$oldJavaPid) {
            $newJavaPid = [int]$state.javaPid
            Write-Operation -Status "completed" -Stage "completed" -Message $(if ($Action -eq "update") { "服务器程序更新完成，新 Java 进程正在运行。" } else { "安全重启已完成，新 Java 进程正在运行。" })
            exit 0
        }
        if ($launchProcess.HasExited) {
            $failure = if ($stateIsCurrent -and $state.failure) { [string]$state.failure } else { "启动脚本提前退出，退出码 $($launchProcess.ExitCode)。" }
            throw $failure
        }
    } while ((Get-Date) -lt $startDeadline)
    throw "启动脚本已执行，但新 Java 进程未在 15 分钟内完成 Steam、Workshop 和网络初始化。"
}
catch {
    Write-Operation -Status "failed" -Stage "failed" -Message "服务器生命周期操作失败。" -ErrorMessage $_.Exception.Message
    exit 1
}
finally {
    if ($steamLockStream) { $steamLockStream.Dispose() }
    if ($lockStream) { $lockStream.Dispose() }
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
}
