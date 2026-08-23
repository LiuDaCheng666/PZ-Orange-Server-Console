param()

$ErrorActionPreference = "Stop"
$projectRoot = $PSScriptRoot
$testRoot = Join-Path $env:TEMP ("PZLifecycleRecovery-" + [guid]::NewGuid().ToString("N"))
$managedRoot = Join-Path $testRoot "managed"
$managedHostPath = Join-Path $managedRoot "Run-ManagedPZHost.ps1"
$managedLifecyclePath = Join-Path $managedRoot "Invoke-ManagedPZLifecycle.ps1"
$utf8 = [Text.UTF8Encoding]::new($false)
$statusCache = $null
$statusCacheAt = [datetime]::MinValue
$auditEvents = @()

function Import-PanelFunction {
    param([string]$Name)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot "PZ-ControlPanel.ps1"), [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "Panel script does not parse." }
    $functionAst = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name
    }, $true)
    if (-not $functionAst) { throw "Function not found: $Name" }
    Set-Item -LiteralPath "Function:\script:$Name" -Value $functionAst.Body.GetScriptBlock()
}

foreach ($name in @(
    "Get-ManagedProfilePaths", "Write-LifecycleRecoveryJson", "Test-LifecycleLockHeld",
    "Test-LifecycleWorkerAlive", "Test-ManagedHostAlive", "Repair-InterruptedLifecycleOperation"
)) { Import-PanelFunction -Name $name }

function Get-RunningProfileProcessInfo { param($Profile) return $null }
function Add-Audit {
    param([string]$Remote, [string]$Action, [string]$Detail, [string]$Result)
    $script:auditEvents += [pscustomobject]@{ action = $Action; detail = $Detail; result = $Result }
}

try {
    $profileRoot = Join-Path $managedRoot "mock"
    New-Item -ItemType Directory -Path $profileRoot -Force | Out-Null
    $profile = [pscustomobject]@{
        id = "mock"
        serverName = "mock-server"
        statePath = Join-Path $profileRoot "state.json"
    }
    $paths = Get-ManagedProfilePaths -Id "mock"
    $staleTime = (Get-Date).AddMinutes(-5).ToString("o")
    $state = [ordered]@{
        status = "stopping"; serverName = "mock-server"; hostPid = 2147483000; javaPid = 2147483001
        startedAt = $staleTime; updatedAt = $staleTime; managed = $true; protocolVersion = 2; priorityClass = "AboveNormal"
    }
    $operation = [ordered]@{
        id = "0123456789abcdef0123456789abcdef"; action = "restart"; trigger = "manual"; serverId = "mock"
        status = "running"; stage = "waiting-stop"; message = "waiting"; startedAt = $staleTime; updatedAt = $staleTime
        workerPid = $null; oldJavaPid = 2147483001; newJavaPid = $null; warnings = @(); error = $null
    }
    [IO.File]::WriteAllText($profile.statePath, ($state | ConvertTo-Json), $utf8)
    [IO.File]::WriteAllText($paths.operationPath, ($operation | ConvertTo-Json), $utf8)
    [IO.File]::WriteAllText($paths.lifecycleLockPath, "stale", $utf8)

    $recovered = Repair-InterruptedLifecycleOperation -Profile $profile
    $recoveredState = Get-Content -LiteralPath $profile.statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$recovered.status -ne "failed" -or [string]$recoveredState.status -ne "stopped" -or
        $recoveredState.javaPid -or $recoveredState.hostPid -or (Test-Path -LiteralPath $paths.lifecycleLockPath)) {
        throw "Interrupted lifecycle operation was not recovered to a clean stopped state."
    }
    if ($auditEvents.Count -ne 1 -or [string]$auditEvents[0].action -ne "lifecycle-recovery") {
        throw "Lifecycle recovery did not create exactly one audit record."
    }

    $operation.status = "running"
    $operation.stage = "waiting-stop"
    $operation.updatedAt = $staleTime
    [IO.File]::WriteAllText($paths.operationPath, ($operation | ConvertTo-Json), $utf8)
    $lockStream = [IO.File]::Open($paths.lifecycleLockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $preserved = Repair-InterruptedLifecycleOperation -Profile $profile
        if ([string]$preserved.status -ne "running") { throw "An actively locked lifecycle operation was incorrectly recovered." }
    }
    finally { $lockStream.Dispose() }

    $lifecycleSource = Get-Content -LiteralPath (Join-Path $projectRoot "managed\Invoke-ManagedPZLifecycle.ps1") -Raw -Encoding UTF8
    if ($lifecycleSource -notmatch '(?m)^\s*workerPid\s*=\s*\$PID\s*$') {
        throw "Lifecycle worker PID is not persisted in operation state."
    }

    [pscustomobject]@{
        ok = $true
        staleOperationRecovered = $true
        staleLockRemoved = $true
        activeLockPreserved = $true
        workerPidPersisted = $true
    } | ConvertTo-Json
}
finally {
    if ($lockStream) { $lockStream.Dispose() }
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $resolvedTempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if ($resolvedTestRoot.StartsWith($resolvedTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
