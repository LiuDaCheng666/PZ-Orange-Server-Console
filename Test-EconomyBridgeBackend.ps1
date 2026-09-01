param()

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
$panelPath = Join-Path $projectRoot 'PZ-ControlPanel.ps1'

function Import-PanelFunction {
    param([string]$Name)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($panelPath, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw 'Panel script does not parse.' }
    $functionAst = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name
    }, $true)
    if (-not $functionAst) { throw "Function not found: $Name" }
    Set-Item -LiteralPath "Function:\script:$Name" -Value $functionAst.Body.GetScriptBlock()
}

$functionNames = @(
    'Get-EconomyProfilePaths', 'Assert-EconomyProfileDataRootUnique', 'Get-EconomyRequestBody',
    'Get-EconomyFiniteDouble', 'Get-EconomyDecimal',
    'Get-EconomyInteger', 'Get-EconomyOptionalText', 'Assert-EconomyReason',
    'Assert-EconomyAccountKey', 'Assert-EconomyToken', 'Throw-EconomyHttpError', 'Assert-EconomyClientToken',
    'Assert-EconomyRequestRateLimit', 'Read-EconomyRuntimeState',
    'Test-EconomyRuntimeStateFresh', 'Assert-EconomyBridgeStateFresh',
    'Assert-EconomyBridgeWritable', 'Add-EconomyJsonLine', 'Add-EconomyCommand',
    'Get-EconomyAccountSnapshot', 'Add-EconomyFlowQuery', 'Add-EconomyBalanceAdjustment',
    'Set-EconomyDonor', 'Set-EconomyDonorSettings', 'Set-EconomyLeaderboardOverride',
    'Clear-EconomyLeaderboardOverride', 'Get-EconomyReceiptPayload'
)
foreach ($name in $functionNames) { Import-PanelFunction -Name $name }
Import-PanelFunction -Name 'Read-Utf8Tail'

$utf8 = [Text.UTF8Encoding]::new($false)
$economyStateMaximumBytes = 4MB
$economyBridgeFreshnessMilliseconds = 30000
$economyCommandCompactBytes = 512KB
$economyRequestRateEvents = [Collections.Generic.List[object]]::new()
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("pz-economy-backend-" + [guid]::NewGuid().ToString('N'))
$resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$resolvedTest = [IO.Path]::GetFullPath($testRoot)
if (-not $resolvedTest.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Temporary test path escaped the operating-system temp directory.'
}

$profile = [pscustomobject]@{
    id = 'test-server'
    name = 'Test Server'
    serverName = 'servertest'
    dataRoot = $testRoot
}
$serverProfiles = @($profile)
$testServerAlive = $true
$auditRows = [Collections.Generic.List[object]]::new()

function Get-ServerProfile {
    param([string]$Id)
    if ($Id -cne $script:profile.id) { throw "Unknown test profile: $Id" }
    return $script:profile
}

function Get-ServerState {
    param($Profile)
    return [pscustomobject]@{ alive = [bool]$script:testServerAlive }
}

function Add-Audit {
    param([string]$Remote, [string]$Action, [string]$Detail, [string]$Result)
    $script:auditRows.Add([pscustomobject]@{ remote = $Remote; action = $Action; detail = $Detail; result = $Result })
}

function Write-TestState {
    param([int64]$UpdatedMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(), [string]$Server = 'servertest', [int]$Schema = 1)
    $paths = Get-EconomyProfilePaths -Profile $script:profile
    New-Item -ItemType Directory -Path (Split-Path -Parent $paths.state) -Force | Out-Null
    $state = [ordered]@{
        schema = $Schema
        server = $Server
        updatedMs = $UpdatedMs
        accounts = @([ordered]@{
            accountKey = 'OrangeTradingModPlayer_Alice'
            playerName = 'Alice'
            balance = 100
            donorToken = 'donor-token-1'
            leaderboardToken = 'leaderboard-token-1'
            leaderboardOverride = $false
        })
        donorSettings = [ordered]@{ hour = 8; message = 'reward'; token = 'settings-token-1' }
        leaderboard = [ordered]@{ rankBalance = @(); rankStockValue = @(); rankKills = @(); rankSurvival = @() }
    }
    [IO.File]::WriteAllText($paths.state, ($state | ConvertTo-Json -Depth 12 -Compress), $script:utf8)
    return $state
}

function Read-TestCommands {
    $path = (Get-EconomyProfilePaths -Profile $script:profile).command
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    return @(Get-Content -LiteralPath $path -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $raised = $false
    try { & $Action } catch { $raised = $true }
    if (-not $raised) { throw $Message }
}

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    function New-TestEconomyRequest {
        param([byte[]]$Bytes, [int64]$ContentLength = -1)
        return [pscustomobject]@{
            ContentLength64 = $ContentLength
            InputStream = [IO.MemoryStream]::new($Bytes, $false)
        }
    }
    $validRequest = New-TestEconomyRequest -Bytes $utf8.GetBytes('{"serverId":"test-server"}') -ContentLength 26
    try {
        $parsedRequest = Get-EconomyRequestBody -Request $validRequest
        if ($parsedRequest.serverId -cne 'test-server') { throw 'A valid economy request body was not parsed.' }
    }
    finally { $validRequest.InputStream.Dispose() }
    $emptyRequest = New-TestEconomyRequest -Bytes ([byte[]]::new(0)) -ContentLength 0
    try { Assert-Throws { Get-EconomyRequestBody -Request $emptyRequest } 'An empty economy request body was accepted.' }
    finally { $emptyRequest.InputStream.Dispose() }
    $declaredOversize = New-TestEconomyRequest -Bytes $utf8.GetBytes('{}') -ContentLength 65537
    try { Assert-Throws { Get-EconomyRequestBody -Request $declaredOversize } 'An oversized Content-Length was accepted.' }
    finally { $declaredOversize.InputStream.Dispose() }
    $streamedOversize = New-TestEconomyRequest -Bytes ([byte[]]::new(65537)) -ContentLength -1
    try { Assert-Throws { Get-EconomyRequestBody -Request $streamedOversize } 'An oversized unknown-length body was accepted.' }
    finally { $streamedOversize.InputStream.Dispose() }

    $paths = Get-EconomyProfilePaths -Profile $profile
    if ($paths.command -notlike "$testRoot*" -or $paths.receipt -notlike "$testRoot*" -or $paths.state -notlike "$testRoot*") {
        throw 'Economy bridge paths escaped the selected profile data root.'
    }
    if ((Split-Path -Leaf $paths.command) -cne 'OrangeCommunityEconomy-economy-commands.txt' -or
            (Split-Path -Leaf $paths.receipt) -cne 'OrangeCommunityEconomy-economy-receipts.txt' -or
            (Split-Path -Leaf $paths.state) -cne 'OrangeCommunityEconomy-economy-state.json') {
        throw 'Economy bridge file names do not match the Mod contract.'
    }

    [void](Write-TestState)
    $state = Read-EconomyRuntimeState -Profile $profile
    if ($state.schema -ne 1 -or $state.server -cne 'servertest' -or -not (Test-EconomyRuntimeStateFresh $state)) {
        throw 'A valid economy state was not accepted.'
    }
    $slotState = Write-TestState -UpdatedMs ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + 1)
    $slotState.updatedMs = [int64]$slotState.updatedMs + 1000
    $slotState.donorSettings.message = 'newest-slot'
    [IO.File]::WriteAllText($paths.stateB, ($slotState | ConvertTo-Json -Depth 12 -Compress), $utf8)
    [IO.File]::WriteAllText($paths.stateA, '{partial', $utf8)
    $newestState = Read-EconomyRuntimeState -Profile $profile
    if ($newestState.donorSettings.message -cne 'newest-slot') {
        throw 'Double-buffered state did not ignore a partial slot and choose the newest valid copy.'
    }
    Remove-Item -LiteralPath $paths.stateA, $paths.stateB -Force
    $serverProfiles = @($profile, [pscustomobject]@{
        id = 'duplicate'; name = 'Duplicate'; serverName = 'server2'; dataRoot = $testRoot
    })
    Assert-Throws { Read-EconomyRuntimeState -Profile $profile } 'A duplicate economy dataRoot was accepted.'
    $serverProfiles = @($profile)
    [void](Write-TestState -Server 'another-server')
    Assert-Throws { Read-EconomyRuntimeState -Profile $profile } 'A state from another server was accepted.'
    [void](Write-TestState -Schema 2)
    Assert-Throws { Read-EconomyRuntimeState -Profile $profile } 'An unsupported state schema was accepted.'
    [void](Write-TestState)
    $savedStateLimit = $economyStateMaximumBytes
    $economyStateMaximumBytes = 32
    Assert-Throws { Read-EconomyRuntimeState -Profile $profile } 'An oversized state file was accepted.'
    $economyStateMaximumBytes = $savedStateLimit

    [void](Write-TestState -UpdatedMs ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - 31000))
    Assert-Throws {
        Add-EconomyBalanceAdjustment -Body ([pscustomobject]@{
            serverId = 'test-server'; accountKey = 'OrangeTradingModPlayer_Alice'; operation = 'add'
            amount = 1; expectedBalance = 100; reason = 'stale test'; confirmation = 'ADJUST_ECONOMY_BALANCE'
        }) -Remote '127.0.0.1' -RequestedBy 'admin'
    } 'A write was accepted with stale Mod state.'

    [void](Write-TestState)
    $testServerAlive = $false
    Assert-Throws {
        Add-EconomyBalanceAdjustment -Body ([pscustomobject]@{
            serverId = 'test-server'; accountKey = 'OrangeTradingModPlayer_Alice'; operation = 'add'
            amount = 1; expectedBalance = 100; reason = 'stopped test'; confirmation = 'ADJUST_ECONOMY_BALANCE'
        }) -Remote '127.0.0.1' -RequestedBy 'admin'
    } 'A write was accepted while the game server was stopped.'
    Assert-Throws {
        Add-EconomyFlowQuery -Body ([pscustomobject]@{
            serverId = 'test-server'; accountKey = 'OrangeTradingModPlayer_Alice'; page = 1; pageSize = 50
            direction = ''; keyword = ''
        }) -RequestedBy 'viewer'
    } 'A flow query was accepted while the game server was stopped.'
    $testServerAlive = $true

    $flow = Add-EconomyFlowQuery -Body ([pscustomobject]@{
        serverId = 'test-server'; accountKey = 'OrangeTradingModPlayer_Alice'; page = 1; pageSize = 50
        direction = 'in'; keyword = 'Alice'
    }) -RequestedBy 'viewer'
    $commands = Read-TestCommands
    $flowRow = $commands[-1]
    if ($flowRow.operation -cne 'query_flows' -or $flowRow.requestId -notmatch '^economy-[a-f0-9]{32}$' -or
            $flowRow.expectedServerName -cne 'servertest' -or $flowRow.requestedBy -cne 'viewer' -or
            [int64]$flowRow.expiresMs - [int64]$flowRow.createdMs -ne 30000 -or
            $flow.requestId -cne $flowRow.requestId -or $flowRow.args.pageSize -ne 50 -or
            $flowRow.args.days -ne 30 -or [string]$flowRow.args.kind -ne '') {
        throw 'Flow-query queue contract is inconsistent.'
    }

    $balance = Add-EconomyBalanceAdjustment -Body ([pscustomobject]@{
        serverId = 'test-server'; accountKey = 'OrangeTradingModPlayer_Alice'; operation = 'add'
        amount = '25.50'; expectedBalance = '100.00'; reason = 'support correction'
        confirmation = 'ADJUST_ECONOMY_BALANCE'
    }) -Remote '127.0.0.1' -RequestedBy 'admin'
    $balanceRow = (Read-TestCommands)[-1]
    if ($balanceRow.operation -cne 'adjust_balance' -or [decimal]$balanceRow.args.amount -ne 25.50D -or
            [decimal]$balanceRow.args.expectedBalance -ne 100D -or
            [int64]$balanceRow.expiresMs - [int64]$balanceRow.createdMs -ne 60000 -or
            $balance.requestId -cne $balanceRow.requestId) {
        throw 'Balance-adjust queue contract is inconsistent.'
    }
    Assert-Throws {
        Add-EconomyBalanceAdjustment -Body ([pscustomobject]@{
            serverId = 'test-server'; accountKey = 'OrangeTradingModPlayer_Alice'; operation = 'add'
            amount = '1.001'; expectedBalance = 100; reason = 'precision'; confirmation = 'ADJUST_ECONOMY_BALANCE'
        }) -Remote '127.0.0.1' -RequestedBy 'admin'
    } 'A balance amount with more than two decimal places was accepted.'
    Assert-Throws { Get-EconomyDecimal -Value 'NaN' -Name 'amount' -Minimum 0.01D -Maximum 10D } 'NaN was accepted as an economy amount.'
    Assert-Throws {
        Add-EconomyBalanceAdjustment -Body ([pscustomobject]@{
            serverId = 'test-server'; accountKey = 'OrangeTradingModPlayer_Alice'; operation = 'add'
            amount = 1; expectedBalance = 100; reason = ''; confirmation = 'ADJUST_ECONOMY_BALANCE'
        }) -Remote '127.0.0.1' -RequestedBy 'admin'
    } 'A write without a management reason was accepted.'
    Assert-Throws {
        Add-EconomyBalanceAdjustment -Body ([pscustomobject]@{
            serverId = 'test-server'; accountKey = 'OrangeTradingModPlayer_Alice'; operation = 'add'
            amount = 1; expectedBalance = 100; reason = 'test'; confirmation = 'WRONG'
        }) -Remote '127.0.0.1' -RequestedBy 'admin'
    } 'A write without the exact secondary confirmation was accepted.'

    [void](Set-EconomyDonor -Body ([pscustomobject]@{
        serverId = 'test-server'; accountKey = 'OrangeTradingModPlayer_Alice'; tier = 2; title = 'Builder'
        r = 90; g = 180; b = 255; steamId = '76561191234567890'; reason = 'donor correction'
        expectedDonorToken = 'donor-token-1'
        confirmation = 'SET_ECONOMY_DONOR'
    }) -Remote '127.0.0.1' -RequestedBy 'admin')
    $donorRow = (Read-TestCommands)[-1]
    if ($donorRow.operation -cne 'set_donor' -or $donorRow.args.expectedDonorToken -cne 'donor-token-1' -or
            $donorRow.args.tier -ne 2 -or $donorRow.args.rewardHour -or $donorRow.args.rewardMessage) {
        throw 'Donor command did not preserve its domain boundary or concurrency token.'
    }
    Assert-Throws {
        Set-EconomyDonor -Body ([pscustomobject]@{
            serverId = 'test-server'; accountKey = 'OrangeTradingModPlayer_Alice'; tier = 1; title = 'Bad'
            r = 1; g = 2; b = 3; steamId = ''; reason = 'bad color'; confirmation = 'SET_ECONOMY_DONOR'
            expectedDonorToken = 'donor-token-1'
        }) -Remote '127.0.0.1' -RequestedBy 'admin'
    } 'A donor color outside the server presets was accepted.'

    [void](Set-EconomyDonorSettings -Body ([pscustomobject]@{
        serverId = 'test-server'; rewardHour = 9; rewardMessage = 'new reward'; reason = 'schedule change'
        expectedSettingsToken = 'settings-token-1'
        confirmation = 'SET_ECONOMY_DONOR_SETTINGS'
    }) -Remote '127.0.0.1' -RequestedBy 'admin')
    $settingsRow = (Read-TestCommands)[-1]
    if ($settingsRow.operation -cne 'set_donor_settings' -or
            $settingsRow.args.expectedSettingsToken -cne 'settings-token-1' -or
            $settingsRow.args.hour -ne 9 -or $settingsRow.args.message -cne 'new reward') {
        throw 'Donor-settings queue contract is inconsistent.'
    }

    [void](Set-EconomyLeaderboardOverride -Body ([pscustomobject]@{
        serverId = 'test-server'; accountKey = 'OrangeTradingModPlayer_Alice'; kills = 123
        hoursSurvived = 456.75; reason = 'rank correction'; confirmation = 'SET_ECONOMY_LEADERBOARD_OVERRIDE'
        expectedLeaderboardToken = 'leaderboard-token-1'
    }) -Remote '127.0.0.1' -RequestedBy 'admin')
    $leaderboardSetRow = (Read-TestCommands)[-1]
    if ($leaderboardSetRow.operation -cne 'set_leaderboard_override' -or
            $leaderboardSetRow.args.expectedLeaderboardToken -cne 'leaderboard-token-1') {
        throw 'Leaderboard override operation name is inconsistent.'
    }
    [void](Clear-EconomyLeaderboardOverride -Body ([pscustomobject]@{
        serverId = 'test-server'; accountKey = 'OrangeTradingModPlayer_Alice'; reason = 'remove correction'
        expectedLeaderboardToken = 'leaderboard-token-1'
        confirmation = 'CLEAR_ECONOMY_LEADERBOARD_OVERRIDE'
    }) -Remote '127.0.0.1' -RequestedBy 'admin')
    $leaderboardClearRow = (Read-TestCommands)[-1]
    if ($leaderboardClearRow.operation -cne 'clear_leaderboard_override' -or
            $leaderboardClearRow.args.expectedLeaderboardToken -cne 'leaderboard-token-1') {
        throw 'Leaderboard clear operation name is inconsistent.'
    }
    Assert-Throws { Get-EconomyFiniteDouble -Value 'Infinity' -Name 'hours' -Minimum 0 -Maximum 10000000 } 'Infinity was accepted for leaderboard hours.'

    $receiptId = 'economy-0123456789abcdef0123456789abcdef'
    $waiting = Get-EconomyReceiptPayload -Profile $profile -RequestId $receiptId
    if ($waiting.status -cne 'waiting' -or $waiting.receipt) { throw 'Missing receipt did not return a non-blocking waiting result.' }
    [IO.File]::WriteAllLines($paths.receipt, @(
        ([ordered]@{ schema = 1; requestId = $receiptId; server = 'servertest'; status = 'queued'; updatedMs = 1 } | ConvertTo-Json -Compress),
        '{malformed',
        ([ordered]@{ schema = 1; requestId = $receiptId; server = 'servertest'; status = 'completed'; updatedMs = 2; result = @{ page = 1 } } | ConvertTo-Json -Depth 5 -Compress)
    ), $utf8)
    $completed = Get-EconomyReceiptPayload -Profile $profile -RequestId $receiptId
    if ($completed.status -cne 'completed' -or $completed.receipt.result.page -ne 1) {
        throw 'The latest matching economy receipt was not returned.'
    }
    Assert-Throws { Get-EconomyReceiptPayload -Profile $profile -RequestId '../bad' } 'An invalid receipt requestId was accepted.'

    [IO.File]::WriteAllText($paths.receipt, ('x' * 1048577) + "`n" +
        ([ordered]@{ schema = 1; requestId = $receiptId; server = 'servertest'; status = 'completed'; updatedMs = 3 } |
            ConvertTo-Json -Compress), $utf8)
    $boundedTail = Get-EconomyReceiptPayload -Profile $profile -RequestId $receiptId
    if ($boundedTail.status -cne 'completed') { throw 'Fixed-size receipt tail did not find the latest bounded receipt.' }

    Assert-Throws {
        Set-EconomyDonor -Body ([pscustomobject]@{
            serverId = 'test-server'; accountKey = 'OrangeTradingModPlayer_Alice'; tier = 2; title = 'Builder'
            r = 90; g = 180; b = 255; steamId = '76561191234567890'; reason = 'stale donor token'
            expectedDonorToken = 'stale-token'; confirmation = 'SET_ECONOMY_DONOR'
        }) -Remote '127.0.0.1' -RequestedBy 'admin'
    } 'A stale browser donor token was replaced with the latest snapshot token.'
    Assert-Throws {
        Set-EconomyDonorSettings -Body ([pscustomobject]@{
            serverId = 'test-server'; rewardHour = 9; rewardMessage = 'new reward'; reason = 'stale settings token'
            expectedSettingsToken = 'stale-token'; confirmation = 'SET_ECONOMY_DONOR_SETTINGS'
        }) -Remote '127.0.0.1' -RequestedBy 'admin'
    } 'A stale browser donor-settings token was replaced with the latest snapshot token.'
    Assert-Throws {
        Set-EconomyLeaderboardOverride -Body ([pscustomobject]@{
            serverId = 'test-server'; accountKey = 'OrangeTradingModPlayer_Alice'; kills = 1
            hoursSurvived = 1; reason = 'stale leaderboard token'; expectedLeaderboardToken = 'stale-token'
            confirmation = 'SET_ECONOMY_LEADERBOARD_OVERRIDE'
        }) -Remote '127.0.0.1' -RequestedBy 'admin'
    } 'A stale browser leaderboard token was replaced with the latest snapshot token.'

    $economyRequestRateEvents = [Collections.Generic.List[object]]::new()
    for ($rateIndex = 0; $rateIndex -lt 6; $rateIndex++) {
        Assert-EconomyRequestRateLimit -RequestedBy 'rate-viewer' -Operation 'query_flows'
    }
    Assert-Throws {
        Assert-EconomyRequestRateLimit -RequestedBy 'rate-viewer' -Operation 'query_flows'
    } 'The per-user flow-query rate limit was not enforced.'
    $economyRequestRateEvents = [Collections.Generic.List[object]]::new()

    $compactPath = Join-Path $testRoot 'compact-commands.txt'
    [IO.File]::WriteAllText($compactPath, "{}`n{}`n", $utf8)
    $savedCompactLimit = $economyCommandCompactBytes
    $economyCommandCompactBytes = 4
    Add-EconomyJsonLine -Path $compactPath -Value ([ordered]@{ schema = 1; requestId = 'new' }) -ConsumedLines 2
    $economyCommandCompactBytes = $savedCompactLimit
    if (@(Get-Content -LiteralPath $compactPath -Encoding UTF8).Count -ne 1) {
        throw 'A fully consumed economy command queue was not compacted before append.'
    }

    if ($auditRows.Count -lt 5 -or @($auditRows | Where-Object result -ceq 'queued').Count -ne $auditRows.Count) {
        throw 'Economy writes were not recorded in the Web audit at enqueue time.'
    }
    $panelSource = Get-Content -LiteralPath $panelPath -Raw -Encoding UTF8
    foreach ($route in @('/api/economy', '/api/economy/flow-query', '/api/economy/receipt',
            '/api/economy/balance-adjust', '/api/economy/donor', '/api/economy/donor-settings',
            '/api/economy/leaderboard')) {
        if (-not $panelSource.Contains($route)) { throw "Economy API route is missing: $route" }
    }

    [pscustomobject]@{
        ok = $true
        stateBoundedAndServerScoped = $true
        staleAndStoppedWritesRejected = $true
        commandsUseSchemaOneAndFixedTtl = $true
        moneyAndParametersValidated = $true
        receiptsAreBoundedAndNonBlocking = $true
        malformedAndConcurrentUpdatesProtected = $true
        rateLimitAndQueueCompactionEnforced = $true
        enqueueAuditRecorded = $true
    } | ConvertTo-Json
}
finally {
    if (Test-Path -LiteralPath $resolvedTest) {
        Remove-Item -LiteralPath $resolvedTest -Recurse -Force
    }
}
