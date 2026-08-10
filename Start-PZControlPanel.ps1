$ErrorActionPreference = "Stop"
$NoBrowser = $args -contains "-NoBrowser"

$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$root = $PSScriptRoot
$statePath = Join-Path $root "panel-state.json"
$serverScript = Join-Path $root "PZ-ControlPanel.ps1"
$initializer = Join-Path $root "Initialize-PortablePanel.ps1"
$firewallScript = Join-Path $root "Update-PZPanelFirewall.ps1"
$configPath = Join-Path $root "panel-config.json"
$port = 8790
if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    try {
        $configuration = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $configuredPort = [int]$configuration.port
        if ($configuredPort -lt 1024 -or $configuredPort -gt 65535) { throw "端口必须为 1024 至 65535。" }
        $port = $configuredPort
    }
    catch { throw "面板端口配置无效：$($_.Exception.Message)" }
}

$address = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" } |
    Sort-Object InterfaceMetric |
    Select-Object -First 1 -ExpandProperty IPAddress
if (-not $address) { $address = "127.0.0.1" }

if (Test-Path -LiteralPath $initializer -PathType Leaf) { & $initializer }

$mobileUrlPath = Join-Path $root "手机访问地址.txt"
$mobileUrl = "http://$address`:$port/"
[IO.File]::WriteAllText($mobileUrlPath, $mobileUrl, [Text.UTF8Encoding]::new($true))

$websiteInfoPath = Join-Path $root "网站信息.txt"
if (Test-Path -LiteralPath $websiteInfoPath -PathType Leaf) {
    try {
        $websiteInfo = Get-Content -LiteralPath $websiteInfoPath -Raw -Encoding UTF8
        $websiteInfo = [regex]::Replace($websiteInfo, '(?m)^本机地址：.*$', "本机地址：http://127.0.0.1:$port/")
        $websiteInfo = [regex]::Replace($websiteInfo, '(?m)^服务器网卡地址：.*$', "服务器网卡地址：$mobileUrl")
        $websiteInfo = [regex]::Replace($websiteInfo, '(?m)^公网地址：.*$', "公网地址：http://<服务器公网IP>:$port/")
        [IO.File]::WriteAllText($websiteInfoPath, $websiteInfo, [Text.UTF8Encoding]::new($true))
    }
    catch {
        Write-Warning "网站信息文件地址更新失败：$($_.Exception.Message)"
    }
}

if (Test-Path -LiteralPath $firewallScript -PathType Leaf) {
    & $firewallScript -Port $port -Quiet | Out-Null
}

if (Test-Path -LiteralPath $statePath) {
    try {
        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $stateProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$($state.pid)" -ErrorAction SilentlyContinue
        if ($stateProcess -and $stateProcess.CommandLine -like "*PZ-ControlPanel.ps1*" -and [int]$state.port -eq $port) {
            if (-not $NoBrowser) { Start-Process "http://127.0.0.1:$port/" }
            exit 0
        }
    } catch { }
}

$arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$serverScript`" -Port $port"
$process = Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -WindowStyle Hidden -PassThru
$deadline = (Get-Date).AddSeconds(15)
do {
    Start-Sleep -Milliseconds 300
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/" -TimeoutSec 2
        if ($response.StatusCode -eq 200) { break }
    } catch { }
    if ($process.HasExited) { throw "控制台后台进程启动失败，退出码 $($process.ExitCode)。" }
} while ((Get-Date) -lt $deadline)
if ((Get-Date) -ge $deadline) { throw "控制台在 15 秒内没有开始监听。" }

if (-not $NoBrowser) { Start-Process "http://127.0.0.1:$port/" }
[pscustomobject]@{
    LocalUrl = "http://127.0.0.1:$port/"
    LanUrl = $mobileUrl
    MobileUrlFile = $mobileUrlPath
    ProcessId = $process.Id
} | Format-List
