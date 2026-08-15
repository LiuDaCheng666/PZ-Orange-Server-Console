param(
    [Parameter(Mandatory = $true)]
    [string]$ProfilePath,

    [string]$AdminPasswordSecretPath
)

$ErrorActionPreference = "Stop"
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
$profile = Get-Content -LiteralPath $ProfilePath -Raw -Encoding UTF8 | ConvertFrom-Json
$startedAt = Get-Date
$process = $null
$adminPassword = $null
$desiredPriorityClass = [Diagnostics.ProcessPriorityClass]::AboveNormal
$appliedPriorityClass = $null
if ([bool]$profile.showConsole) {
    try { $Host.UI.RawUI.WindowTitle = "PZ Server - $([string]$profile.serverName)" } catch { }
}

function Write-Receipt {
    param($Request, [string]$Status, [AllowNull()]$Extra)
    if (-not $Request -or [string]::IsNullOrWhiteSpace([string]$Request.id) -or -not [bool]$Request.requireReceipt) { return }
    $receiptDir = if ($profile.receiptDir) { [string]$profile.receiptDir } else { Join-Path ([string]$profile.queueDir) "..\receipts" }
    New-Item -ItemType Directory -Path $receiptDir -Force | Out-Null
    $receipt = [ordered]@{
        id = [string]$Request.id
        command = [string]$Request.command
        status = $Status
        hostPid = $PID
        updatedAt = (Get-Date).ToString("o")
    }
    if ($Extra) {
        foreach ($property in $Extra.PSObject.Properties) { $receipt[$property.Name] = $property.Value }
    }
    $path = Join-Path $receiptDir "$([string]$Request.id).json"
    $tempPath = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($tempPath, ($receipt | ConvertTo-Json -Depth 4), $utf8)
        Move-Item -LiteralPath $tempPath -Destination $path -Force
    }
    finally { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
}

function Write-State {
    param([string]$Status, [AllowNull()]$Process, [AllowNull()]$Extra)
    $state = [ordered]@{
        status = $Status
        serverName = [string]$profile.serverName
        hostPid = $PID
        javaPid = if ($Process -and -not $Process.HasExited) { $Process.Id } else { $null }
        startedAt = $startedAt.ToString("o")
        updatedAt = (Get-Date).ToString("o")
        managed = $true
        protocolVersion = 2
        priorityClass = $appliedPriorityClass
    }
    if ($Extra) {
        foreach ($property in $Extra.PSObject.Properties) { $state[$property.Name] = $property.Value }
    }
    $tempPath = "$($profile.statePath).$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($tempPath, ($state | ConvertTo-Json -Depth 4), $utf8)
        Move-Item -LiteralPath $tempPath -Destination ([string]$profile.statePath) -Force
    }
    finally { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
}

function Get-CommandLineArgument {
    param([string]$CommandLine, [string]$Name)
    $match = [regex]::Match($CommandLine, "(?i)(?:^|\s)-$([regex]::Escape($Name))(?:=|\s+)(?:`"([^`"]+)`"|(\S+))")
    if (-not $match.Success) { return $null }
    if ($match.Groups[1].Success) { return $match.Groups[1].Value }
    return $match.Groups[2].Value
}

function Test-ProcessMatchesProfile {
    param($Candidate)
    if (-not $Candidate -or [string]$Candidate.Name -notmatch '^java(w)?\.exe$' -or
        [string]$Candidate.ExecutablePath -ine [string]$profile.javaPath -or
        [string]$Candidate.CommandLine -notlike '*zombie.network.GameServer*') { return $false }

    $commandLine = [string]$Candidate.CommandLine
    $serverName = Get-CommandLineArgument -CommandLine $commandLine -Name "servername"
    if ([string]::IsNullOrWhiteSpace($serverName)) { $serverName = "servertest" }
    if ($serverName -ine [string]$profile.serverName) { return $false }

    $dataRoot = Get-CommandLineArgument -CommandLine $commandLine -Name "cachedir"
    if ([string]::IsNullOrWhiteSpace($dataRoot)) { $dataRoot = Join-Path $env:USERPROFILE "Zomboid" }
    try { return [IO.Path]::GetFullPath($dataRoot) -ieq [IO.Path]::GetFullPath([string]$profile.dataRoot) }
    catch { return $false }
}

function Quote-WindowsArgument {
    param([string]$Value)
    if ($Value -match '[\x00-\x1f\x7f"]') { throw "Invalid first-run admin password characters." }
    return '"' + ([regex]::Replace($Value, '(\\+)$', '$1$1')) + '"'
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

New-Item -ItemType Directory -Path ([string]$profile.dataRoot), ([string]$profile.queueDir) -Force | Out-Null
if ($profile.receiptDir) { New-Item -ItemType Directory -Path ([string]$profile.receiptDir) -Force | Out-Null }
$gcLogArgument = Get-JvmGcLogPathArgument -Arguments ([string]$profile.arguments)
if (-not [string]::IsNullOrWhiteSpace($gcLogArgument)) {
    $gcLogPath = if ([IO.Path]::IsPathRooted($gcLogArgument)) {
        [IO.Path]::GetFullPath($gcLogArgument)
    } else {
        [IO.Path]::GetFullPath((Join-Path ([string]$profile.workingDirectory) $gcLogArgument))
    }
    $gcLogDirectory = Split-Path -Parent $gcLogPath
    if (-not [string]::IsNullOrWhiteSpace($gcLogDirectory)) {
        New-Item -ItemType Directory -Path $gcLogDirectory -Force | Out-Null
    }
}
$hostProcess = [Diagnostics.Process]::GetCurrentProcess()
$hostProcess.PriorityClass = $desiredPriorityClass
$hostProcess.Refresh()
if ($hostProcess.PriorityClass -ne $desiredPriorityClass) {
    throw "Failed to set the managed host process priority to AboveNormal."
}
$existing = Get-CimInstance Win32_Process -Filter "Name='java.exe' OR Name='javaw.exe'" -OperationTimeoutSec 2 -ErrorAction SilentlyContinue | Where-Object {
    Test-ProcessMatchesProfile -Candidate $_
} | Select-Object -First 1
if ($existing) { throw "The PZ Java process is already running (PID $($existing.ProcessId))." }

Get-ChildItem -LiteralPath ([string]$profile.queueDir) -Filter "*.json" -File -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = [string]$profile.javaPath
$startInfo.Arguments = [string]$profile.arguments
if (-not [string]::IsNullOrWhiteSpace($AdminPasswordSecretPath)) {
    $secretPath = [IO.Path]::GetFullPath($AdminPasswordSecretPath)
    $controlRoot = [IO.Path]::GetFullPath((Split-Path -Parent $ProfilePath)).TrimEnd('\') + '\'
    $secretName = [IO.Path]::GetFileName($secretPath)
    if (-not $secretPath.StartsWith($controlRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $secretName -notmatch '^admin-launch-[a-f0-9]{32}\.bin$') {
        throw "Invalid first-run admin secret path."
    }
    if (-not (Test-Path -LiteralPath $secretPath -PathType Leaf)) { throw "First-run admin secret is missing or expired." }
    if (((Get-Date).ToUniversalTime() - (Get-Item -LiteralPath $secretPath).LastWriteTimeUtc).TotalMinutes -gt 10) {
        Remove-Item -LiteralPath $secretPath -Force -ErrorAction SilentlyContinue
        throw "First-run admin secret has expired."
    }
    Add-Type -AssemblyName System.Security
    $protectedBytes = $null
    $plainBytes = $null
    try {
        $protectedBytes = [IO.File]::ReadAllBytes($secretPath)
        $plainBytes = [Security.Cryptography.ProtectedData]::Unprotect(
            $protectedBytes,
            $null,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        $adminPassword = $utf8.GetString($plainBytes)
        if ([string]::IsNullOrWhiteSpace($adminPassword) -or $adminPassword.Length -lt 8 -or $adminPassword.Length -gt 128) {
            throw "First-run admin password is invalid."
        }
        $startInfo.Arguments += " -adminpassword $(Quote-WindowsArgument -Value $adminPassword)"
    }
    finally {
        Remove-Item -LiteralPath $secretPath -Force -ErrorAction SilentlyContinue
        if ($plainBytes) { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
        if ($protectedBytes) { [Array]::Clear($protectedBytes, 0, $protectedBytes.Length) }
    }
}
$startInfo.WorkingDirectory = [string]$profile.workingDirectory
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = -not [bool]$profile.showConsole
$startInfo.RedirectStandardInput = $true
$process = [Diagnostics.Process]::new()
$process.StartInfo = $startInfo

Write-State -Status "starting" -Process $null -Extra $null
try {
    if (-not $process.Start()) { throw "Failed to start the Java process." }
    $process.PriorityClass = $desiredPriorityClass
    $process.Refresh()
    if ($process.PriorityClass -ne $desiredPriorityClass) {
        throw "Failed to set the Java process priority to AboveNormal."
    }
    $appliedPriorityClass = [string]$process.PriorityClass
    $adminPassword = $null
    Write-State -Status "starting" -Process $process -Extra $null
    $runningWritten = $false
    while (-not $process.HasExited) {
        if (-not $runningWritten) {
            $runningWritten = $true
            Write-State -Status "running" -Process $process -Extra $null
        }
        $commands = @(Get-ChildItem -LiteralPath ([string]$profile.queueDir) -Filter "*.json" -File -ErrorAction SilentlyContinue |
            Sort-Object CreationTimeUtc)
        foreach ($commandFile in $commands) {
            try {
                $request = Get-Content -LiteralPath $commandFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                $command = [string]$request.command
                if ([string]::IsNullOrWhiteSpace($command) -or $command -match "[\r\n]" -or $command.Length -gt 512) {
                    throw "Invalid queued command."
                }
                $bytes = $utf8.GetBytes($command + "`n")
                $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
                $process.StandardInput.BaseStream.Flush()
                Write-Receipt -Request $request -Status "accepted" -Extra ([pscustomobject]@{ acceptedAt = (Get-Date).ToString("o") })
                if ($command -eq "save") {
                    $deadline = (Get-Date).AddSeconds(12)
                    while ((Get-Date) -lt $deadline -and -not $process.HasExited) { Start-Sleep -Milliseconds 250 }
                    if ($process.HasExited) { throw "Java process exited while waiting for save to settle." }
                    Write-Receipt -Request $request -Status "completed" -Extra ([pscustomobject]@{
                        completedAt = (Get-Date).ToString("o")
                        confirmation = "stdin-flushed-and-process-stable"
                    })
                }
                else {
                    Write-Receipt -Request $request -Status "completed" -Extra ([pscustomobject]@{
                        completedAt = (Get-Date).ToString("o")
                        confirmation = "stdin-flushed"
                    })
                }
                if ($command -eq "quit") { Write-State -Status "stopping" -Process $process -Extra $null }
            }
            catch {
                Write-Receipt -Request $request -Status "failed" -Extra ([pscustomobject]@{ error = $_.Exception.Message })
            }
            finally { Remove-Item -LiteralPath $commandFile.FullName -Force -ErrorAction SilentlyContinue }
        }
        Start-Sleep -Milliseconds 400
    }
    $exitCode = [int]$process.ExitCode
    $exitStatus = if ($exitCode -eq 0) { "stopped" } else { "failed" }
    $exitExtra = [ordered]@{
        exitCode = $exitCode
        finishedAt = (Get-Date).ToString("o")
    }
    if ($exitCode -ne 0) { $exitExtra.failure = "Java process exited with code $exitCode." }
    Write-State -Status $exitStatus -Process $process -Extra ([pscustomobject]$exitExtra)
}
catch {
    if ($process -and -not $process.HasExited) {
        try { $process.Kill() } catch { }
    }
    Write-State -Status "failed" -Process $process -Extra ([pscustomobject]@{ failure = $_.Exception.Message })
    throw
}
finally {
    if ($process) { $process.Dispose() }
}
