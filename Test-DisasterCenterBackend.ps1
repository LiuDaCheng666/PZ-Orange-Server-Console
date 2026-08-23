param()

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
$testRoot = Join-Path $env:TEMP ("pz-disaster-center-test-" + [guid]::NewGuid().ToString('N'))
$utf8 = [Text.UTF8Encoding]::new($false)
$disasterCenterRoot = Join-Path $testRoot 'panel-disasters'
$disasterCenterStorePath = Join-Path $disasterCenterRoot 'store.json'
$disasterSchedulerLastTick = [datetime]::MinValue
$disasterQueryAt = @{}
$auditRecords = @()

function Import-PanelFunction {
    param([string]$Name)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'PZ-ControlPanel.ps1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw 'Panel script does not parse.' }
    $functionAst = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name
    }, $true)
    if (-not $functionAst) { throw "Function not found: $Name" }
    Set-Item -LiteralPath "Function:\script:$Name" -Value $functionAst.Body.GetScriptBlock()
}

foreach ($name in @(
    'Assert-SimpleText', 'Add-AdminItemVaultJsonLine', 'Read-AdminItemVaultJsonLines',
    'New-DisasterCenterStore', 'Read-DisasterCenterStore', 'Save-DisasterCenterStore',
    'Get-DisasterProfilePaths', 'ConvertTo-DisasterParameters', 'Normalize-DisasterTemplate',
    'Add-DisasterCommand', 'Read-DisasterRuntimeState', 'Sync-DisasterReceipts',
    'Invoke-DisasterSchedulerTick', 'Get-DisasterCenterPayload', 'Save-DisasterTemplate',
    'Remove-DisasterTemplate', 'Start-DisasterTemplateNow', 'Stop-DisasterRuntimeEvent',
    'Add-DisasterQueueEntry', 'Remove-DisasterQueueEntry'
)) { Import-PanelFunction -Name $name }

function Add-Audit {
    param([string]$Remote, [string]$Action, [string]$Detail, [string]$Result = 'queued')
    $script:auditRecords += [pscustomobject]@{ action = $Action; result = $Result; detail = $Detail }
}

function Get-ServerProfile {
    param([string]$Id)
    $profile = $script:serverProfiles | Where-Object { [string]$_.id -ceq $Id } | Select-Object -First 1
    if (-not $profile) { throw "Unknown profile: $Id" }
    return $profile
}

New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$serverProfiles = @(
    [pscustomobject]@{ id = 'one'; name = 'Server One'; serverName = 'servertest'; dataRoot = (Join-Path $testRoot 'one') },
    [pscustomobject]@{ id = 'two'; name = 'Server Two'; serverName = 'server2'; dataRoot = (Join-Path $testRoot 'two') }
)
foreach ($profile in $serverProfiles) { New-Item -ItemType Directory -Path (Join-Path $profile.dataRoot 'Lua') -Force | Out-Null }

try {
    $saved = Save-DisasterTemplate -Remote 'test' -RequestedBy 'admin' -Body ([pscustomobject]@{
        id = ''
        name = 'Severe Nuclear Winter'
        kind = 'nuclear_winter'
        durationDays = 2
        params = [pscustomobject]@{ temperature = -28; cropYieldMultiplier = 0.4; ambient = 0.35 }
    })
    if ([string]$saved.template.id -notmatch '^disaster-template-') { throw 'Template ID was not generated.' }
    if ([double]$saved.template.params.cropYieldMultiplier -ne 0.4) { throw 'Template parameters changed while saving.' }

    $start = Start-DisasterTemplateNow -Remote 'test' -RequestedBy 'admin' -Body ([pscustomobject]@{
        serverId = 'one'; templateId = $saved.template.id
    })
    $paths = Get-DisasterProfilePaths $serverProfiles[0]
    $commands = @(Read-AdminItemVaultJsonLines -Path $paths.command)
    if ($commands.Count -ne 1 -or [string]$commands[0].value.operation -cne 'start') { throw 'Start command was not written.' }
    if ($commands[0].value.args.concurrent -ne $true -or [double]$commands[0].value.args.cropYieldMultiplier -ne 0.4) {
        throw 'Start command lost concurrency or template parameters.'
    }

    Add-AdminItemVaultJsonLine -Path $paths.receipt -Value ([ordered]@{
        schema = 1; requestId = $start.request.requestId; operation = 'start'; status = 'completed'
        code = 'started'; detail = 'nuclear_winter'; updatedMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    })
    [IO.File]::WriteAllText($paths.state, ([ordered]@{
        schema = 1; server = 'servertest'; updatedMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        state = [ordered]@{
            schemaVersion = 8; revision = 3; serverWorldHour = 120.5
            activeEvents = @([ordered]@{ eventId = 'event-1'; kind = 'nuclear_winter'; endsAtHour = 168.5 })
            prayer = [ordered]@{ total = 1250; donors = @(); recent = @() }
        }
    } | ConvertTo-Json -Depth 20), $utf8)
    $payload = Get-DisasterCenterPayload -ServerId 'one' -RequestedBy 'admin'
    if ([double]$payload.runtime.state.prayer.total -ne 1250) { throw 'Runtime prayer total was not exposed.' }
    $request = $payload.requests | Where-Object { [string]$_.requestId -ceq [string]$start.request.requestId } | Select-Object -First 1
    if ([string]$request.status -cne 'completed') { throw 'Command receipt was not synchronized.' }

    $queued = Add-DisasterQueueEntry -Remote 'test' -RequestedBy 'admin' -Body ([pscustomobject]@{
        serverId = 'two'; templateId = $saved.template.id; scheduledAt = (Get-Date).AddMinutes(-1).ToString('o')
    })
    $script:disasterSchedulerLastTick = [datetime]::MinValue
    Invoke-DisasterSchedulerTick
    $store = Read-DisasterCenterStore
    $queueRow = $store.queue | Where-Object { [string]$_.id -ceq [string]$queued.entry.id } | Select-Object -First 1
    if ([string]$queueRow.status -cne 'dispatched' -or [string]::IsNullOrWhiteSpace([string]$queueRow.requestId)) {
        throw 'Due queue entry was not dispatched.'
    }
    $serverTwoCommands = @(Read-AdminItemVaultJsonLines -Path (Get-DisasterProfilePaths $serverProfiles[1]).command)
    if ($serverTwoCommands.Count -ne 1 -or [string]$serverTwoCommands[0].value.operation -cne 'start') {
        throw 'Scheduled start command was not written to target server.'
    }

    [void](Stop-DisasterRuntimeEvent -Remote 'test' -RequestedBy 'admin' -Body ([pscustomobject]@{
        serverId = 'one'; eventId = 'event-1'
    }))
    $commands = @(Read-AdminItemVaultJsonLines -Path $paths.command)
    if ($commands.Count -ne 2 -or [string]$commands[1].value.operation -cne 'stop' -or
            [string]$commands[1].value.args.eventId -cne 'event-1') { throw 'Stop command was not written correctly.' }

    $future = Add-DisasterQueueEntry -Remote 'test' -RequestedBy 'admin' -Body ([pscustomobject]@{
        serverId = 'one'; templateId = $saved.template.id; scheduledAt = (Get-Date).AddHours(1).ToString('o')
    })
    [void](Remove-DisasterQueueEntry -Remote 'test' -RequestedBy 'admin' -Body ([pscustomobject]@{ id = $future.entry.id }))
    $store = Read-DisasterCenterStore
    $store.queue = @($store.queue | Where-Object { [string]$_.id -cne [string]$queued.entry.id })
    Save-DisasterCenterStore $store
    [void](Remove-DisasterTemplate -Remote 'test' -RequestedBy 'admin' -Body ([pscustomobject]@{ id = $saved.template.id }))
    if ((Read-DisasterCenterStore).templates.Count -ne 0) { throw 'Template was not deleted.' }

    [pscustomobject]@{
        ok = $true
        prayerTotal = 1250
        startReceipt = 'completed'
        scheduledDispatch = 'completed'
        stopCommand = 'completed'
        audits = $auditRecords.Count
    } | ConvertTo-Json
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
