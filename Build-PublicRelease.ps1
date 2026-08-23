param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot "dist-public"),
    [string]$Version = "0.9.7",
    [string]$PackageName
)

$ErrorActionPreference = "Stop"
$source = [IO.Path]::GetFullPath($PSScriptRoot)
$output = [IO.Path]::GetFullPath($OutputDirectory)
if ([string]::IsNullOrWhiteSpace($PackageName)) {
    $PackageName = "PZ-Orange-ControlPanel-GitHub-$Version"
}
if ([IO.Path]::GetFileName($PackageName) -ne $PackageName) {
    throw "PackageName 只能是文件名，不能包含目录。"
}

function Assert-ChildPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Parent
    )
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $resolvedParent = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    if (-not $resolvedPath.StartsWith($resolvedParent, [StringComparison]::OrdinalIgnoreCase)) {
        throw "拒绝操作工作目录以外的路径：$resolvedPath"
    }
    return $resolvedPath
}

function Copy-RequiredFile {
    param([string]$Name, [string]$DestinationName = $Name)
    $sourcePath = Join-Path $source $Name
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "缺少发行文件：$sourcePath"
    }
    $destinationPath = Join-Path $stage $DestinationName
    $destinationDirectory = Split-Path -Parent $destinationPath
    if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    }
    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
}

function Copy-RequiredDirectory {
    param([string]$Name)
    $sourcePath = Join-Path $source $Name
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
        throw "缺少发行目录：$sourcePath"
    }
    Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $stage $Name) -Recurse -Force
}

function Assert-PublicPackageContents {
    param([string]$Root)

    $forbiddenNames = @(
        "access-token.txt",
        "ai-config.json",
        "ai-credential.dat",
        "ai-state.json",
        "ai-history.json",
        "ai-moderation-events.json",
        "users.json",
        "servers.json",
        "execution-history.json",
        "audit.log",
        "broadcast-schedules.json",
        "maintenance-schedules.json",
        "server-patches.json",
        "anticheat-review-state.json",
        "panel-state.json",
        "request-state.json",
        "手机访问地址.txt"
    )
    $forbiddenFiles = @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File | Where-Object {
        $_.Name -in $forbiddenNames -or
        $_.Name -like "*.bak" -or
        $_.Name -like "*.log" -or
        $_.Name -like "*.tmp" -or
        $_.FullName.StartsWith((Join-Path $Root "disaster-center") + '\', [StringComparison]::OrdinalIgnoreCase)
    })
    if ($forbiddenFiles.Count -gt 0) {
        throw "公开包中发现运行态或敏感文件：$(@($forbiddenFiles.FullName) -join ', ')"
    }

    $textExtensions = @(".ps1", ".psm1", ".js", ".html", ".css", ".json", ".md", ".txt", ".bat", ".cmd")
    $privateMarkers = @(
        [regex]::Escape($env:USERPROFILE),
        [regex]::Escape($source),
        '(?i)\bsk-[A-Za-z0-9_-]{16,}\b',
        '(?i)\b(api[_ -]?key|token|password)\s*[:=]\s*["''][A-Za-z0-9_./+=-]{16,}["'']'
    )
    $scanMatches = @()
    foreach ($file in Get-ChildItem -LiteralPath $Root -Recurse -Force -File) {
        if ([IO.Path]::GetExtension($file.Name).ToLowerInvariant() -notin $textExtensions) { continue }
        $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 -ErrorAction Stop
        foreach ($marker in $privateMarkers) {
            if ($content -match $marker) {
                $scanMatches += "$($file.FullName) => $marker"
            }
        }
    }
    if ($scanMatches.Count -gt 0) {
        throw "公开包敏感信息扫描未通过：$($scanMatches -join '; ')"
    }
}

if (-not (Test-Path -LiteralPath $output -PathType Container)) {
    New-Item -ItemType Directory -Path $output -Force | Out-Null
}
$stage = Assert-ChildPath -Path (Join-Path $output $PackageName) -Parent $output
$zipPath = Assert-ChildPath -Path (Join-Path $output "$PackageName.zip") -Parent $output
$hashPath = Assert-ChildPath -Path (Join-Path $output "$PackageName.sha256.txt") -Parent $output

foreach ($path in @($stage, $zipPath, $hashPath)) {
    if (-not (Test-Path -LiteralPath $path)) { continue }
    if ((Get-Item -LiteralPath $path).PSIsContainer) {
        Remove-Item -LiteralPath $path -Recurse -Force
    }
    else {
        Remove-Item -LiteralPath $path -Force
    }
}

New-Item -ItemType Directory -Path $stage, (Join-Path $stage "managed"), (Join-Path $stage "runtime"), (Join-Path $stage "web"), (Join-Path $stage "服务器信息库"), (Join-Path $stage "docs\images") -Force | Out-Null

$rootFiles = @(
    "PZ-ControlPanel.ps1",
    "PZ-AIBridge.ps1",
    "Start-PZControlPanel.ps1",
    "Stop-PZControlPanel.ps1",
    "Run-PZPanelAtStartup.ps1",
    "Set-PZPanelStartupTask.ps1",
    "Configure-PZPanelAutoLogon.ps1",
    "Update-PZPanelFirewall.ps1",
    "Set-PZPanelPort.ps1",
    "Reset-AdminPassword.ps1",
    "Initialize-PortablePanel.ps1",
    "Build-PZServerKnowledgeBase.ps1",
    "Build-PZItemIndex.js",
    "Manage-PZPlayerData.js",
    "Manage-PZBanList.js",
    "Read-PZAntiCheatEvents.js",
    "Build-PZPlayerAuditEvidence.js",
    "PLAYER-AUDIT-SOP.zh-CN.md",
    "Build-PublicRelease.ps1",
    "Read-PZPlayers.js",
    "一键启动Web面板.bat",
    "停止Web面板.bat",
    "修改面板端口.bat",
    "本机重置admin密码.bat",
    "配置自动进入桌面.bat",
    "便携版使用说明.txt",
    "AI配置说明.txt",
    "PZAI-Mod执行器改写SOP.md",
    "Test-ControlFeatures.ps1",
    "Test-ControlFeaturesBrowser.js",
    "Test-HostControl.ps1",
    "Test-HostControlBrowser.js",
    "Test-InitialAdminStartup.ps1",
    "Test-ManagedLifecycle.ps1",
    "Test-ManagedStartupSerialization.ps1",
    "Test-MaintenanceRestartState.ps1",
    "Test-LifecycleRecovery.ps1",
    "Test-JvmGcTelemetry.ps1",
    "Test-StockEventBridge.ps1",
    "Test-AIKnowledgeBuilder.ps1",
    "Test-AIKnowledgeBuildPipeline.ps1",
    "Test-ItemGrantCommandResults.ps1",
    "Test-ItemGrantNotification.ps1",
    "Test-ProfileGameSettingsSync.ps1",
    "Test-MaintenanceBrowser.js",
    "Test-PlayerDataPermissions.ps1",
    "Test-PZPlayerDataManager.js",
    "Test-AdminItemVaultBackend.ps1",
    "Test-AdminItemVaultBrowser.js",
    "Test-DisasterCenterBackend.ps1",
    "Test-PlayerAuditAI.ps1",
    "Test-PlayerAuditAIRetry.ps1",
    "CHANGELOG.md",
    "SECURITY.md",
    "panel-config.json",
    "ai-config.example.json",
    ".gitignore",
    ".gitattributes"
)
foreach ($name in $rootFiles) {
    Copy-RequiredFile -Name $name
}
Copy-RequiredFile -Name "README-GitHub.zh-CN.md" -DestinationName "README.md"
Copy-RequiredFile -Name "managed\Run-ManagedPZHost.ps1"
Copy-RequiredFile -Name "managed\Invoke-ManagedPZLifecycle.ps1"
Copy-RequiredDirectory -Name "patches"
Get-ChildItem -LiteralPath (Join-Path $stage "patches") -Recurse -Force -File -Filter "*.bak" |
    Remove-Item -Force
foreach ($name in @(
    "Invoke-PZSelectiveWorldReset.ps1",
    "pz_selective_world_reset.py",
    "README.md"
)) {
    Copy-RequiredFile -Name "tools\PZSelectiveWorldReset\$name"
}
Copy-RequiredDirectory -Name "skill"
foreach ($name in @("index.html", "app.css", "app.js", "lucide.min.js", "qrcode.min.js")) {
    Copy-RequiredFile -Name "web\$name"
}

$screenshots = [ordered]@{
    "pz-panel-control-features-desktop.png" = "docs\images\maintenance-and-history.png"
    "pz-panel-item-catalog-playwright.png" = "docs\images\item-catalog.png"
    "pz-panel-ai-policy-mobile.png" = "docs\images\ai-bridge-and-policy.png"
    "pz-panel-host-control-desktop.png" = "docs\images\host-control.png"
    "pz-panel-control-features-mobile.png" = "docs\images\mobile-console.png"
}
foreach ($entry in $screenshots.GetEnumerator()) {
    Copy-RequiredFile -Name $entry.Key -DestinationName $entry.Value
}

$nodePath = Join-Path $source "runtime\node.exe"
if (-not (Test-Path -LiteralPath $nodePath -PathType Leaf)) {
    $node = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($node) { $nodePath = $node.Source }
}
if (-not (Test-Path -LiteralPath $nodePath -PathType Leaf)) {
    throw "找不到 Node.js 运行时。请安装 Node.js，或放置 runtime\node.exe 后重试。"
}
Copy-Item -LiteralPath $nodePath -Destination (Join-Path $stage "runtime\node.exe") -Force
Copy-RequiredFile -Name "runtime\NODE-LICENSE.txt"

$utf8Bom = [Text.UTF8Encoding]::new($true)
$websiteInfo = @"
PZ 橙子服务器控制台 - 网站信息
================================

本机地址：http://127.0.0.1:8790/
服务器网卡地址：首次启动后自动更新
公网地址：http://<服务器公网IP>:8790/

首次管理员：
1. 本发行包不包含预设账号或密码。
2. 第一次必须在服务器本机打开 http://127.0.0.1:8790/。
3. 页面会要求创建 Web 面板 admin 管理员。
4. 第一个管理员不允许通过公网或局域网地址创建。

启动与网络：
1. 完整解压 ZIP，不要在压缩包内直接运行。
2. 双击“一键启动Web面板.bat”。
3. 同意 Windows 管理员授权后，启动器会尝试开放面板 TCP 端口。
4. 公网云服务器还需在云厂商安全组中开放同一 TCP 端口。

AI：
- API Key 不包含在发行包内。
- 在新服务器本机登录后进入“AI 助手”配置 Provider、接口、模型和 API Key。
- API Key 使用当前 Windows 用户的 DPAPI 加密，不能从另一台电脑直接迁移。
"@
[IO.File]::WriteAllText((Join-Path $stage "网站信息.txt"), $websiteInfo, $utf8Bom)

$knowledgeReadme = @"
PZ 橙子服务器控制台 - 服务器信息库
==================================

将本服规则、Mod 用法、活动说明、常见问题等资料放在此目录。面板内置 AI 会把这些
文件作为补充证据检索。

支持格式：
md、txt、json、ini、cfg、lua、yaml、yml、csv

建议每个主题一个文件，并写清：
- 适用服务器名称
- 生效日期或版本
- Workshop ID / Mod ID
- 具体规则或配置项
- 管理员希望 AI 使用的标准回答

证据优先级：
1. 当前服务器只读配置和实时遥测
2. 本目录中的服务器资料
3. 一般游戏机制知识

当资料与当前配置冲突时，AI 应以当前配置和实时遥测为准。没有本服证据时，AI 应
明确说明无法确认，不应把默认值或经验当成本服设置。

不要写入：
API Key、Web 密码、游戏 admin 密码、RCON 密码、Token、Steam 登录凭据、玩家隐私、
本机私有路径或不应向普通玩家公开的信息。
"@
[IO.File]::WriteAllText((Join-Path $stage "服务器信息库\README.txt"), $knowledgeReadme, $utf8Bom)

Assert-PublicPackageContents -Root $stage
Compress-Archive -LiteralPath $stage -DestinationPath $zipPath -CompressionLevel Optimal
$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText($hashPath, "$hash  $([IO.Path]::GetFileName($zipPath))`r`n", [Text.UTF8Encoding]::new($false))

[pscustomobject]@{
    Package = $PackageName
    Folder = $stage
    Zip = $zipPath
    Sha256 = $hash
    Sha256File = $hashPath
    SizeBytes = (Get-Item -LiteralPath $zipPath).Length
}
