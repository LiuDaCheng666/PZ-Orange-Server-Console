param(
    [Parameter(Mandatory = $true)][string]$PythonPath,
    [Parameter(Mandatory = $true)][string]$ToolPath,
    [Parameter(Mandatory = $true)][string]$SaveRoot,
    [Parameter(Mandatory = $true)][string]$ServerName,
    [Parameter(Mandatory = $true)][string]$ManualAreas,
    [Parameter(Mandatory = $true)][int]$SafehouseMargin,
    [Parameter(Mandatory = $true)][int]$PlayerMargin,
    [Parameter(Mandatory = $true)][int]$AnimalMargin,
    [Parameter(Mandatory = $true)][string]$ReportRoot,
    [ValidateSet("audit", "apply", "rollback")][string]$Mode = "audit",
    [string]$Confirmation = "",
    [string]$Quarantine = "",
    [string]$ProgressPath = ""
)

$ErrorActionPreference = "Stop"
$arguments = @(
    $ToolPath,
    "--save-root", $SaveRoot,
    "--server-name", $ServerName,
    "--manual-areas", $ManualAreas,
    "--safehouse-margin-chunks", [string]$SafehouseMargin,
    "--player-margin-chunks", [string]$PlayerMargin,
    "--animal-margin-chunks", [string]$AnimalMargin,
    "--report-dir", $ReportRoot
)
if (-not [string]::IsNullOrWhiteSpace($ProgressPath)) {
    $arguments += @("--progress-path", $ProgressPath)
}
if ($Mode -eq "apply") {
    $arguments += @("--apply", "--confirmation", $Confirmation)
}
elseif ($Mode -eq "rollback") {
    $arguments += @("--rollback", "--quarantine", $Quarantine, "--confirmation", $Confirmation)
}

$exitCodePath = Join-Path (Split-Path -Parent $ReportRoot) "exit-code.txt"
$exitCode = 1
try {
    & $PythonPath @arguments
    $exitCode = $LASTEXITCODE
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    $exitCode = 1
}
finally {
    [IO.File]::WriteAllText($exitCodePath, [string]$exitCode, [Text.UTF8Encoding]::new($false))
}
exit $exitCode
