param(
    [securestring]$NewPassword,
    [string]$MaintenanceCode
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$usersPath = Join-Path $root "users.json"
$iterations = 310000
$utf8 = [Text.UTF8Encoding]::new($false)

if ([string]::IsNullOrWhiteSpace($MaintenanceCode)) {
    $MaintenanceCode = Read-Host "请输入本机维护码"
}
if ($MaintenanceCode -cne "2338191290") {
    throw "维护码错误，未修改 admin 账号。"
}

if (-not $NewPassword) {
    $NewPassword = Read-Host "请输入 admin 的新密码（10 至 128 个字符）" -AsSecureString
}

$credential = [pscredential]::new("admin", $NewPassword)
$plainPassword = $credential.GetNetworkCredential().Password
if ([string]::IsNullOrWhiteSpace($plainPassword) -or $plainPassword.Length -lt 10 -or $plainPassword.Length -gt 128) {
    throw "密码必须为 10 至 128 个字符。"
}

$users = @()
if (Test-Path -LiteralPath $usersPath -PathType Leaf) {
    $document = Get-Content -LiteralPath $usersPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $users = @($document.users)
}

$admin = $users | Where-Object { [string]$_.username -ieq "admin" } | Select-Object -First 1
$now = (Get-Date).ToString("o")
if (-not $admin) {
    $admin = [pscustomobject][ordered]@{
        id = [guid]::NewGuid().ToString("N")
        username = "admin"
        displayName = "Administrator"
        passwordSalt = ""
        passwordHash = ""
        iterations = $iterations
        enabled = $true
        createdAt = $now
        updatedAt = $now
        sessionVersion = 1
    }
    $users = @($users) + @($admin)
}

$salt = [byte[]]::new(32)
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
try { $rng.GetBytes($salt) } finally { $rng.Dispose() }
$derive = [Security.Cryptography.Rfc2898DeriveBytes]::new(
    $plainPassword,
    $salt,
    $iterations,
    [Security.Cryptography.HashAlgorithmName]::SHA256
)
try { $hash = $derive.GetBytes(32) } finally { $derive.Dispose() }

$admin.username = "admin"
$admin.passwordSalt = [Convert]::ToBase64String($salt)
$admin.passwordHash = [Convert]::ToBase64String($hash)
$admin.iterations = $iterations
$admin.enabled = $true
$admin.updatedAt = $now
$admin.sessionVersion = [int]$admin.sessionVersion + 1

$tempPath = "$usersPath.$([guid]::NewGuid().ToString('N')).tmp"
try {
    $json = [ordered]@{ version = 1; users = @($users) } | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($tempPath, $json, $utf8)
    Move-Item -LiteralPath $tempPath -Destination $usersPath -Force
}
finally {
    $plainPassword = $null
    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
}

Write-Host "admin 密码已在本机重置。已登录会话将在面板下一次读取用户状态时失效。" -ForegroundColor Green
