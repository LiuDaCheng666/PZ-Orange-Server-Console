param()

$ErrorActionPreference = 'Stop'
$panelPath = Join-Path $PSScriptRoot 'PZ-ControlPanel.ps1'

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

foreach ($name in @(
    'Get-CommunityProfilePaths', 'Assert-CommunityProfileDataRootUnique', 'Get-CommunityText',
    'Get-CommunityNumber', 'Assert-CommunityReason', 'Get-CommunityCommandMap',
    'Get-CommunityCommandDefinition', 'Read-CommunityRuntimeState', 'Test-CommunityRuntimeStateFresh',
    'Test-CommunityCommandConsumer', 'Read-CommunityJsonLines', 'Add-CommunityJsonLine',
    'Get-CommunityReceiptPayload', 'Get-CommunityQueueEntries', 'Get-CommunityPayload',
    'Get-CommunityLedgerPayload', 'ConvertTo-CommunityCommandArguments', 'Add-CommunityAdminCommand'
)) { Import-PanelFunction $name }

$utf8 = [Text.UTF8Encoding]::new($false)
$communityStateMaximumBytes = 4MB
$communityQueueMaximumBytes = 512KB
$communityCommandCompactBytes = 256KB
$communityBridgeFreshnessMilliseconds = 45000
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("pz-community-bridge-" + [guid]::NewGuid().ToString('N'))
$profiles = @(
    [pscustomobject]@{ id = 'one'; name = '一服'; serverName = 'servertest'; dataRoot = (Join-Path $testRoot 'one') },
    [pscustomobject]@{ id = 'two'; name = '二服'; serverName = 'server2'; dataRoot = (Join-Path $testRoot 'two') }
)
$serverProfiles = $profiles
$auditRows = [Collections.Generic.List[object]]::new()

function Get-ServerProfile {
    param([string]$Id)
    $profile = $script:profiles | Where-Object id -CEQ $Id | Select-Object -First 1
    if (-not $profile) { throw "Unknown server $Id" }
    return $profile
}
function Get-ServerState { param($Profile) return [pscustomobject]@{ alive = $true } }
function Test-EconomyManagePermission { param($Session) return $true }
function Add-Audit {
    param([string]$Remote, [string]$Action, [string]$Detail, [string]$Result)
    $script:auditRows.Add([pscustomobject]@{ action = $Action; detail = $Detail; result = $Result })
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $raised = $false
    try { & $Action } catch { $raised = $true }
    if (-not $raised) { throw $Message }
}
function Write-TestState {
    param($Profile = $script:profiles[0], [int64]$UpdatedMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(),
        [string]$Server = '')
    $paths = Get-CommunityProfilePaths $Profile
    New-Item -ItemType Directory -Path (Split-Path -Parent $paths.state) -Force | Out-Null
    $state = [ordered]@{
        schema = 1; server = $(if ($Server) { $Server } else { $Profile.serverName })
        updatedMs = $UpdatedMs; revision = 12
        bridge = [ordered]@{ commandConsumer = $true; commandSchema = 1; queueCursor = 0 }
        governance = [ordered]@{
            revision = 7
            offices = [ordered]@{ chairman = [ordered]@{ role = 'chairman'; username = 'Alice'; endsAtGameHour = 220 } }
            election = [ordered]@{ phase = 'voting'; votingDays = 4; termDays = 30 }
            law = [ordered]@{ governmentForm = 'constitutional'; votingDays = 4; termDays = 30; voteFee = 5;
                purchaseLimit = '50'; welfareDaily = 50; honorBonus = 1000; donationsEnabled = $true; version = 3 }
        }
        treasury = [ordered]@{
            revision = 4; balance = 12345.67; reserved = 500; available = 11845.67
            day = [ordered]@{ day = 20; income = 350; expense = 80 }
            ledger = @(
                [ordered]@{ id = 1; day = 20; timestamp = 1770000000; direction = '收入'; category = 'transaction_tax';
                    categoryName = '交易税'; explanation = '市场成交税收'; amount = 350; balance = 12345.67;
                    details = [ordered]@{ actorName = 'Alice'; targetName = '社区国库'; summary = '车辆成交'; item = 'Base.CarNormal' } },
                [ordered]@{ id = 2; day = 20; timestamp = 1770000100; direction = '支出'; category = 'official_salary';
                    categoryName = '官员工资'; explanation = '向官员发放工资'; amount = 80; balance = 12265.67;
                    details = [ordered]@{ targetName = 'Bob'; summary = '财政委员工资' } }
            )
        }
        crisis = [ordered]@{
            revision = 2; settings = [ordered]@{
                populationBaseline = 15
                economic = [ordered]@{ baseGrowth = 10; multiplier = 1; threshold = 1000; triggerDurationDays = 3 }
                horde = [ordered]@{ baseGrowth = 20; multiplier = 1.5; threshold = 2000 }
                bridge = [ordered]@{ safehouseTitle = 'luyisi'; rallyX = 13000; rallyY = 920; rallyZ = 0; batchSize = 1500; returnAckTimeoutHours = 1 }
            }
            economic = [ordered]@{ value = 120 }; horde = [ordered]@{ threat = 450; defense = 800 }
            population = [ordered]@{ previousDayAverage = 12.5 }
        }
    }
    [IO.File]::WriteAllText($paths.state, ($state | ConvertTo-Json -Depth 20 -Compress), $utf8)
    return $state
}

try {
    foreach ($profile in $profiles) { New-Item -ItemType Directory -Path (Join-Path $profile.dataRoot 'Lua') -Force | Out-Null }
    $paths = Get-CommunityProfilePaths $profiles[0]
    if ($paths.state -notlike "$(Join-Path $profiles[0].dataRoot 'Lua')*" -or
            $paths.command -notlike '*OrangeCommunityEconomy-community-commands.txt' -or
            $paths.receipt -notlike '*OrangeCommunityEconomy-community-receipts.txt') {
        throw 'Community bridge paths are not server-scoped or do not match the contract.'
    }

    [void](Write-TestState)
    $payload = Get-CommunityPayload -Profile $profiles[0] -Session ([pscustomobject]@{})
    if ($payload.bridge.status -cne 'connected' -or $payload.snapshot.governance.offices.chairman.username -cne 'Alice') {
        throw 'A valid connected community snapshot was not exposed.'
    }
    $newer = Write-TestState -UpdatedMs ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + 1000)
    $newer.treasury.balance = 15000
    [IO.File]::WriteAllText($paths.stateB, ($newer | ConvertTo-Json -Depth 20 -Compress), $utf8)
    [IO.File]::WriteAllText($paths.stateA, '{partial', $utf8)
    if ([double](Read-CommunityRuntimeState $profiles[0]).treasury.balance -ne 15000) {
        throw 'Double-buffered community state did not select the newest valid slot.'
    }
    Remove-Item $paths.stateA, $paths.stateB -Force
    [void](Write-TestState -Server 'server2')
    Assert-Throws { Read-CommunityRuntimeState $profiles[0] } 'A snapshot from another server was accepted.'
    [void](Write-TestState)

    $ledger = Get-CommunityLedgerPayload -Profile $profiles[0] -Page 1 -PageSize 10 -Direction '收入' -Kind '' -Keyword '车辆'
    if ($ledger.total -ne 1 -or $ledger.rows[0].categoryName -cne '交易税') {
        throw 'Nested Chinese treasury ledger search or paging failed.'
    }
    $ledgerByPerson = Get-CommunityLedgerPayload -Profile $profiles[0] -Page 1 -PageSize 10 -Direction '支出' -Kind 'official_salary' -Keyword 'Bob'
    if ($ledgerByPerson.total -ne 1) { throw 'Treasury category and nested target-name filtering failed.' }

    $command = Add-CommunityAdminCommand -Body ([pscustomobject]@{
        serverId = 'one'; operation = 'admin_override_law'; reason = '测试法律调整'; expectedRevision = 12
        confirmation = 'COMMUNITY_ADMIN_COMMAND'; args = [pscustomobject]@{
            governmentForm = 'democratic'; votingDays = 8; termDays = 60; voteFee = 10
        }
    }) -Remote '127.0.0.1' -RequestedBy 'admin'
    $commands = @(Read-CommunityJsonLines $paths.command)
    if ($command.requestId -notmatch '^community-[a-f0-9]{32}$' -or $commands[-1].expectedServerName -cne 'servertest' -or
            $commands[-1].operation -cne 'admin_override_law' -or $commands[-1].args.governmentForm -cne 'democratic') {
        throw 'Community command queue contract is inconsistent.'
    }
    Assert-Throws {
        Add-CommunityAdminCommand -Body ([pscustomobject]@{
            serverId = 'one'; operation = 'admin_override_law'; reason = '旧页面提交'; expectedRevision = 11
            confirmation = 'COMMUNITY_ADMIN_COMMAND'; args = [pscustomobject]@{
                governmentForm = 'constitutional'; votingDays = 4; termDays = 30; voteFee = 0
            }
        }) -Remote '127.0.0.1' -RequestedBy 'admin'
    } 'A stale community revision was accepted.'

    Add-CommunityJsonLine -Path $paths.receipt -Value ([ordered]@{
        schema = 1; requestId = $command.requestId; server = 'server2'; status = 'failed'; detail = 'wrong server'
    })
    $waiting = Get-CommunityReceiptPayload -Profile $profiles[0] -RequestId $command.requestId
    if ($waiting.status -cne 'waiting') { throw 'A cross-server ACK was accepted.' }
    Add-CommunityJsonLine -Path $paths.receipt -Value ([ordered]@{
        schema = 1; requestId = $command.requestId; expectedServerName = 'servertest'; status = 'completed';
        code = 'ok'; detail = '法律已更新'
    })
    $completed = Get-CommunityReceiptPayload -Profile $profiles[0] -RequestId $command.requestId
    if ($completed.status -cne 'completed' -or $completed.receipt.detail -cne '法律已更新') {
        throw 'The latest matching Mod ACK was not returned.'
    }
    Assert-Throws { Get-CommunityReceiptPayload -Profile $profiles[0] -RequestId '../bad' } 'An invalid requestId was accepted.'

    $compactPath = Join-Path $profiles[0].dataRoot 'Lua\compact-community.txt'
    [IO.File]::WriteAllLines($compactPath, @('{"old":1}', '{"old":2}'), $utf8)
    $communityCommandCompactBytes = 1
    Add-CommunityJsonLine -Path $compactPath -Value ([ordered]@{ newest = 4 }) -ConsumedLines 2
    $compacted = @(Get-Content $compactPath -Encoding UTF8)
    if ($compacted.Count -ne 1 -or $compacted[0] -notmatch 'newest') {
        throw 'A fully consumed community queue was not compacted safely.'
    }

    [pscustomobject]@{
        ok = $true; serverScopedFiles = $true; doubleBufferedSnapshot = $true
        requestIdAndRevisionContract = $true; crossServerAckRejected = $true
        chineseLedgerPaging = $true; consumedQueueCompaction = $true; audits = $auditRows.Count
    } | ConvertTo-Json
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
