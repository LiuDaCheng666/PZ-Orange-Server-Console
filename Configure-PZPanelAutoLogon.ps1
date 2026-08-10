param()

$ErrorActionPreference = "Stop"
$toolRoot = Join-Path $PSScriptRoot "runtime\sysinternals"
$toolPath = Join-Path $toolRoot "Autologon64.exe"
$downloadUrl = "https://live.sysinternals.com/Autologon64.exe"

New-Item -ItemType Directory -Path $toolRoot -Force | Out-Null
if (-not (Test-Path -LiteralPath $toolPath -PathType Leaf)) {
    Write-Host "Downloading Microsoft Sysinternals Autologon..."
    Invoke-WebRequest -UseBasicParsing -Uri $downloadUrl -OutFile $toolPath
    Unblock-File -LiteralPath $toolPath -ErrorAction SilentlyContinue
}

Write-Host "The Microsoft Autologon window will open. Enter the Windows account password locally, then click Enable."
Write-Host "The password is handled by the Microsoft tool and is not sent to or stored by the Web panel."
Start-Process -FilePath $toolPath -WorkingDirectory $toolRoot -Wait

