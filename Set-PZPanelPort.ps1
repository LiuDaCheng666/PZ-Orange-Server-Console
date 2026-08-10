param(
    [ValidateRange(1024, 65535)]
    [int]$Port
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$configPath = Join-Path $root "panel-config.json"
$statePath = Join-Path $root "panel-state.json"
$firewallScript = Join-Path $root "Update-PZPanelFirewall.ps1"
$startScript = Join-Path $root "Start-PZControlPanel.ps1"
$stopScript = Join-Path $root "Stop-PZControlPanel.ps1"
$utf8 = [Text.UTF8Encoding]::new($false)

if (-not $Port) {
    $inputPort = Read-Host "请输入新的 Web 面板端口（1024 至 65535）"
    if (-not [int]::TryParse($inputPort, [ref]$Port) -or $Port -lt 1024 -or $Port -gt 65535) {
        throw "端口必须为 1024 至 65535 的整数。"
    }
}

$isAdministrator = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdministrator) {
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Port $Port"
    $elevated = Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    if ($elevated.ExitCode -ne 0) { throw "管理员端口修改进程失败，退出码 $($elevated.ExitCode)。" }
    exit 0
}

$oldPort = 8790
if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    try { $oldPort = [int](Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json).port }
    catch { throw "现有 panel-config.json 无法读取。" }
}

$listeners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
if ($listeners.Count -gt 0 -and $Port -ne $oldPort) {
    $owners = @($listeners.OwningProcess | Sort-Object -Unique) -join ","
    throw "TCP $Port 已被进程 $owners 占用，请选择其他端口。"
}

& $firewallScript -Port $Port -Quiet | Out-Null
$newConfiguration = [ordered]@{ port = $Port }
$tempConfig = "$configPath.$([guid]::NewGuid().ToString('N')).tmp"
[IO.File]::WriteAllText($tempConfig, ($newConfiguration | ConvertTo-Json), $utf8)
Move-Item -LiteralPath $tempConfig -Destination $configPath -Force

try {
    if (Test-Path -LiteralPath $statePath) { & $stopScript }
    & $startScript -NoBrowser | Out-Null
    $response = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/api/auth/session" -TimeoutSec 5
    if ($response.StatusCode -ne 200) { throw "新端口 HTTP 健康检查失败。" }
}
catch {
    $failure = $_.Exception.Message
    [IO.File]::WriteAllText($configPath, ([ordered]@{ port = $oldPort } | ConvertTo-Json), $utf8)
    try { & $firewallScript -Port $oldPort -Quiet | Out-Null } catch { }
    try {
        if (Test-Path -LiteralPath $statePath) { & $stopScript }
        & $startScript -NoBrowser | Out-Null
    }
    catch { }
    throw "切换到 TCP $Port 失败，已尝试恢复 TCP $oldPort：$failure"
}

Write-Host "面板端口已从 TCP $oldPort 修改为 TCP $Port。" -ForegroundColor Green
Write-Host "本机地址：http://127.0.0.1:$Port/"
Write-Host "局域网地址已写入：$(Join-Path $root '手机访问地址.txt')"
Write-Host "游戏服务器没有停止或重启。"
