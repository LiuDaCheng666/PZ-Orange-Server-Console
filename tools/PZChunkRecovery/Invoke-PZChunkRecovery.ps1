param(
    [Parameter(Mandatory = $true)][string]$PythonPath,
    [Parameter(Mandatory = $true)][string]$ToolPath,
    [Parameter(Mandatory = $true)][ValidateSet("audit", "restore", "rollback")][string]$Mode,
    [string]$SaveRoot = "",
    [Parameter(Mandatory = $true)][string]$ServerName,
    [string]$DataRoot = "",
    [string]$RecoveryRoot = "",
    [string]$ReportPath = "",
    [string]$BackupPath = "",
    [string]$Chunks = "",
    [string]$TransactionDir = "",
    [string]$Confirmation = "",
    [string]$ProgressPath = "",
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [Parameter(Mandatory = $true)][string]$ErrorPath,
    [Parameter(Mandatory = $true)][string]$ExitCodePath
)

$ErrorActionPreference = "Stop"
$arguments = @($ToolPath, $Mode, "--server-name", $ServerName)
if ($Mode -eq "audit") {
    $arguments += @("--save-root", $SaveRoot, "--report-path", $ReportPath)
    if ($ProgressPath) { $arguments += @("--progress-path", $ProgressPath) }
}
elseif ($Mode -eq "restore") {
    $arguments += @(
        "--save-root", $SaveRoot,
        "--data-root", $DataRoot,
        "--recovery-root", $RecoveryRoot,
        "--backup", $BackupPath,
        "--chunks", $Chunks,
        "--confirmation", $Confirmation
    )
    if ($ProgressPath) { $arguments += @("--progress-path", $ProgressPath) }
}
else {
    $arguments += @(
        "--transaction-dir", $TransactionDir,
        "--confirmation", $Confirmation
    )
}

$exitCode = 1
try {
    $output = @(& $PythonPath @arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { [string]$_ }) -join "`n"
    if ($exitCode -eq 0) {
        [IO.File]::WriteAllText($ResultPath, $text, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($ErrorPath, "", [Text.UTF8Encoding]::new($false))
    }
    else {
        [IO.File]::WriteAllText($ErrorPath, $text, [Text.UTF8Encoding]::new($false))
    }
}
catch {
    [IO.File]::WriteAllText($ErrorPath, $_.Exception.ToString(), [Text.UTF8Encoding]::new($false))
    $exitCode = 1
}
finally {
    [IO.File]::WriteAllText($ExitCodePath, [string]$exitCode, [Text.UTF8Encoding]::new($false))
}
exit $exitCode
