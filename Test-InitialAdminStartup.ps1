param()

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$hostSource = Join-Path $root "managed\Run-ManagedPZHost.ps1"
$testRoot = Join-Path $env:TEMP ("pz-admin-startup-test-" + [guid]::NewGuid().ToString("N"))
$controlRoot = Join-Path $testRoot "managed\test"
$queueDir = Join-Path $controlRoot "commands"
$receiptDir = Join-Path $controlRoot "receipts"
$statePath = Join-Path $controlRoot "state.json"
$profilePath = Join-Path $controlRoot "profile.json"
$hostPath = Join-Path $testRoot "managed\Run-ManagedPZHost.ps1"
$mockJavaPath = Join-Path $testRoot "java.exe"
$capturePath = Join-Path $testRoot "arguments.json"
$utf8 = [Text.UTF8Encoding]::new($false)

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-Secret {
    param([string]$Password, [switch]$Expired)
    Add-Type -AssemblyName System.Security
    $path = Join-Path $controlRoot ("admin-launch-" + [guid]::NewGuid().ToString("N") + ".bin")
    $plain = $utf8.GetBytes($Password)
    try {
        $protected = [Security.Cryptography.ProtectedData]::Protect(
            $plain,
            $null,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        [IO.File]::WriteAllBytes($path, $protected)
    }
    finally {
        if ($plain) { [Array]::Clear($plain, 0, $plain.Length) }
    }
    if ($Expired) { (Get-Item -LiteralPath $path).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(-11) }
    return $path
}

function Invoke-HostTest {
    param([AllowNull()][string]$SecretPath)
    Remove-Item -LiteralPath $capturePath, $statePath -Force -ErrorAction SilentlyContinue
    $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $hostPath, "-ProfilePath", $profilePath)
    if ($SecretPath) { $arguments += @("-AdminPasswordSecretPath", $SecretPath) }
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & powershell.exe @arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = @($output) }
}

try {
    New-Item -ItemType Directory -Path $controlRoot, $queueDir, $receiptDir -Force | Out-Null
    Copy-Item -LiteralPath $hostSource -Destination $hostPath -Force
    Copy-Item -LiteralPath (Get-Command powershell.exe).Source -Destination $mockJavaPath -Force

    $mockScript = Join-Path $testRoot "mock-server.ps1"
    $gcLogPath = Join-Path $testRoot "missing\logs\jvm-gc.log"
    $gcLogArgument = $gcLogPath.Replace('\', '/')
    [IO.File]::WriteAllText($mockScript, @'
param(
    [string]$adminpassword,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Remaining
)
$capture = [ordered]@{ adminPassword = $adminpassword; remaining = @($Remaining) }
[IO.File]::WriteAllText($env:PZ_ADMIN_TEST_CAPTURE, ($capture | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
Start-Sleep -Milliseconds 250
'@, $utf8)

    $profile = [ordered]@{
        id = "test"
        serverName = "isolated-admin-test"
        dataRoot = $testRoot
        javaPath = $mockJavaPath
        workingDirectory = $testRoot
        arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$mockScript`" -Xlog:gc*:file=$($gcLogArgument):time,uptime:filecount=5,filesize=20M --base-marker"
        queueDir = $queueDir
        receiptDir = $receiptDir
        statePath = $statePath
        showConsole = $false
    }
    [IO.File]::WriteAllText($profilePath, ($profile | ConvertTo-Json -Depth 5), $utf8)
    $env:PZ_ADMIN_TEST_CAPTURE = $capturePath

    $withoutSecret = Invoke-HostTest
    Assert-True ($withoutSecret.ExitCode -eq 0) "Host failed without a secret: $($withoutSecret.Output -join ' ')"
    Assert-True (Test-Path -LiteralPath (Split-Path -Parent $gcLogPath) -PathType Container) "Host did not create the JVM log parent directory."
    $withoutCapture = Get-Content -LiteralPath $capturePath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ([string]::IsNullOrEmpty([string]$withoutCapture.adminPassword)) "Normal startup included -adminpassword."

    $password = 'Admin test pass 42\'
    $secret = New-Secret -Password $password
    $withSecret = Invoke-HostTest -SecretPath $secret
    Assert-True ($withSecret.ExitCode -eq 0) "Host failed with a valid secret: $($withSecret.Output -join ' ')"
    $withCapture = Get-Content -LiteralPath $capturePath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True (-not [string]::IsNullOrEmpty([string]$withCapture.adminPassword)) "Initial startup did not include -adminpassword."
    Assert-True ([string]$withCapture.adminPassword -ceq $password) "Password with spaces and trailing backslash was changed."
    Assert-True (-not (Test-Path -LiteralPath $secret)) "Host did not delete the consumed secret file."

    $profileText = Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8
    Assert-True ($profileText -notmatch [regex]::Escape($password)) "Password was persisted in profile.json."
    Assert-True ($profileText -notmatch '(?i)-adminpassword') "profile.json includes -adminpassword."

    $outside = Join-Path $testRoot ("admin-launch-" + [guid]::NewGuid().ToString("N") + ".bin")
    [IO.File]::WriteAllBytes($outside, [byte[]](1, 2, 3))
    $outsideResult = Invoke-HostTest -SecretPath $outside
    Assert-True ($outsideResult.ExitCode -ne 0) "A secret outside the control directory was accepted."

    $expired = New-Secret -Password "Expired pass 42" -Expired
    $expiredResult = Invoke-HostTest -SecretPath $expired
    Assert-True ($expiredResult.ExitCode -ne 0) "An expired secret was accepted."
    Assert-True (-not (Test-Path -LiteralPath $expired)) "Expired secret was not deleted."

    "PASS: isolated initial admin startup tests"
}
finally {
    Remove-Item Env:PZ_ADMIN_TEST_CAPTURE -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
