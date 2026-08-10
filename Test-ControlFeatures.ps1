param()

$ErrorActionPreference = "Stop"
$projectRoot = $PSScriptRoot
$testRoot = Join-Path $env:TEMP ("PZControlFeatures-" + [guid]::NewGuid().ToString("N"))
$utf8 = [Text.UTF8Encoding]::new($false)
$aiOperationPoliciesPath = Join-Path $testRoot "ai-operation-policies.json"
$broadcastSchedulesPath = Join-Path $testRoot "broadcast-schedules.json"
$executionHistoryPath = Join-Path $testRoot "execution-history.json"
$aiOperationPolicies = @()
$broadcastSchedules = @()
$executionHistory = @()

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
    "Read-AIOperationPolicies", "Save-AIOperationPolicies",
    "Read-BroadcastSchedules", "Save-BroadcastSchedules", "Get-BroadcastSchedulesPayload",
    "Read-ExecutionHistory", "Save-ExecutionHistory", "Add-ExecutionHistoryRecord", "Get-ExecutionHistoryPayload",
    "Invoke-BroadcastSchedule", "Invoke-BroadcastSchedulerTick"
)) { Import-PanelFunction -Name $name }

function Add-Audit { param([string]$Remote, [string]$Action, [string]$Detail, [string]$Result) }
function Get-ServerProfile { param([string]$Id) return [pscustomobject]@{ id = $Id; name = "Mock"; consoleLog = $null } }
function Get-BroadcastCommands { param([string]$Message) return @("servermsg `"$Message`"") }
function Queue-Command { throw "Mock command channel unavailable." }

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $now = (Get-Date).ToString("o")
    $script:aiOperationPolicies = @([pscustomobject][ordered]@{
        id = "policy1"; serverId = "mock"; username = "Alice"; steamId = "76561198000000001"
        enabled = $true; trustedAll = $false; allowedOperations = @("query_status", "give_self_item")
        createdAt = $now; updatedAt = $now
    })
    Save-AIOperationPolicies
    $script:aiOperationPolicies = @()
    $script:aiOperationPolicies = @(Read-AIOperationPolicies)
    if ($aiOperationPolicies.Count -ne 1 -or [string]$aiOperationPolicies[0].steamId -ne "76561198000000001") {
        throw "AI operation policy persistence failed."
    }

    $script:broadcastSchedules = @([pscustomobject][ordered]@{
        id = "schedule1"; serverId = "mock"; name = "Test broadcast"; enabled = $true; channel = "native"
        intervalMinutes = 30; title = "Server notice"; message = "Test message"; duration = 15; style = "info"
        nextRunAt = $null; lastRunAt = $null; lastStatus = "never"; lastMessage = "Not run yet."
        createdAt = $now; updatedAt = $now
    })
    Save-BroadcastSchedules
    $script:broadcastSchedules = @()
    $script:broadcastSchedules = @(Read-BroadcastSchedules)
    $loadedSchedule = $broadcastSchedules[0]
    if (-not $loadedSchedule -or $loadedSchedule.intervalMinutes -ne 30) { throw "Broadcast schedule persistence failed." }

    Invoke-BroadcastSchedule -Schedule $loadedSchedule
    if ($loadedSchedule.lastStatus -ne "failed" -or [string]::IsNullOrWhiteSpace([string]$loadedSchedule.nextRunAt)) {
        throw "Failed broadcast did not record its result and next run."
    }
    if ($executionHistory.Count -ne 1 -or $executionHistory[0].category -ne "broadcast" -or $executionHistory[0].status -ne "failed") {
        throw "Failed broadcast was not added to execution history."
    }

    $script:executionHistory = @(Read-ExecutionHistory)
    $payload = Get-ExecutionHistoryPayload -ServerId "mock" -Limit 10
    if ($payload.records.Count -ne 1 -or $payload.records[0].summary -ne "Test broadcast") {
        throw "Execution history persistence failed."
    }
    $script:executionHistory = @(1..65 | ForEach-Object {
        [pscustomobject][ordered]@{
            id = "history$_"; serverId = "mock"; category = $(if ($_ % 2 -eq 0) { "query" } else { "command" })
            action = "test"; source = "web"; summary = "History $_"; status = "success"; resultCode = "ok"
            message = "done"; detail = ""; requestIds = @(); auxiliaryRequestIds = @(); noticeId = ""; operationId = ""
            createdAt = (Get-Date).AddSeconds($_).ToString("o"); updatedAt = (Get-Date).AddSeconds($_).ToString("o")
        }
    })
    $firstPage = Get-ExecutionHistoryPayload -ServerId "mock" -Page 1 -PageSize 30
    $lastPage = Get-ExecutionHistoryPayload -ServerId "mock" -Page 3 -PageSize 30
    $queryPage = Get-ExecutionHistoryPayload -ServerId "mock" -Category "query" -Page 1 -PageSize 30
    if ($firstPage.records.Count -ne 30 -or $firstPage.total -ne 65 -or $firstPage.totalPages -ne 3 -or
            $lastPage.records.Count -ne 5 -or $queryPage.total -ne 32 -or $queryPage.totalPages -ne 2) {
        throw "Execution history pagination failed."
    }

    $script:broadcastLastDispatchAt = @{}
    $script:broadcastDispatchSpacingSeconds = 30
    $script:schedulerDispatches = @()
    Set-Item -LiteralPath "Function:\script:Invoke-BroadcastSchedule" -Value {
        param($Schedule)
        $script:schedulerDispatches += [string]$Schedule.id
        $Schedule.lastRunAt = (Get-Date).ToString("o")
        $Schedule.nextRunAt = (Get-Date).AddHours(1).ToString("o")
    }
    $script:broadcastSchedules = @(
        [pscustomobject]@{ id = "due1"; serverId = "mock"; name = "Due 1"; enabled = $true; intervalMinutes = 60; nextRunAt = $null; lastRunAt = $null; lastStatus = "never"; lastMessage = "" },
        [pscustomobject]@{ id = "due2"; serverId = "mock"; name = "Due 2"; enabled = $true; intervalMinutes = 60; nextRunAt = $null; lastRunAt = $null; lastStatus = "never"; lastMessage = "" }
    )
    Invoke-BroadcastSchedulerTick
    if ($schedulerDispatches.Count -ne 1 -or $schedulerDispatches[0] -ne "due1") {
        throw "Broadcast scheduler did not stagger simultaneous due schedules."
    }
    $script:broadcastLastDispatchAt["mock"] = (Get-Date).AddSeconds(-31)
    Invoke-BroadcastSchedulerTick
    if ($schedulerDispatches.Count -ne 2 -or $schedulerDispatches[1] -ne "due2") {
        throw "Broadcast scheduler did not release the next due schedule after spacing."
    }

    [pscustomobject]@{
        ok = $true
        policyPersistence = $true
        broadcastPersistence = $true
        failedBroadcastStatus = [string]$loadedSchedule.lastStatus
        nextRunRecorded = -not [string]::IsNullOrWhiteSpace([string]$loadedSchedule.nextRunAt)
        historyRecords = $payload.records.Count
        historyPages = $firstPage.totalPages
        filteredHistoryRecords = $queryPage.total
        staggeredBroadcasts = $schedulerDispatches.Count
    } | ConvertTo-Json
}
finally {
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $resolvedTempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if ($resolvedTestRoot.StartsWith($resolvedTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
