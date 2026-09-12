param()

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
$testRoot = Join-Path $env:TEMP ("pz-admin-vault-test-" + [guid]::NewGuid().ToString('N'))
$utf8 = [Text.UTF8Encoding]::new($false)
$adminItemVaultRoot = Join-Path $testRoot 'panel-vault'
$adminItemVaultStorePath = Join-Path $adminItemVaultRoot 'store.json'
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
    'Assert-SimpleText', 'New-AdminItemVaultStore', 'Read-AdminItemVaultStore', 'Save-AdminItemVaultStore',
    'Get-AdminItemVaultProfilePaths', 'Read-AdminItemVaultJsonLines', 'Add-AdminItemVaultJsonLine', 'Add-AdminItemVaultJsonLines',
    'Test-AdminItemVaultTemplateRecord', 'Import-AdminItemVaultTemplates', 'Publish-AdminItemVaultTemplates', 'Sync-AdminItemVaultReceipts',
    'Get-AdminItemVaultPayload', 'Resolve-AdminItemVaultGrantTargets', 'Add-AdminItemVaultGrant', 'Remove-AdminItemVaultTemplate',
    'Get-AdminItemVaultReceiptPayload', 'Get-AdminItemVaultReceiptBatchPayload'
)) { Import-PanelFunction -Name $name }

function Add-Audit {
    param([string]$Remote, [string]$Action, [string]$Detail, [string]$Result = 'queued')
    $script:auditRecords += [pscustomobject]@{ remote = $Remote; action = $Action; detail = $Detail; result = $Result }
}

function Get-ServerProfile {
    param([string]$Id)
    $profile = $script:serverProfiles | Where-Object { [string]$_.id -ceq $Id } | Select-Object -First 1
    if (-not $profile) { throw "Unknown profile: $Id" }
    return $profile
}

function Get-PlayerDirectory {
    param($Profile)
    return [ordered]@{
        onlineKnown = $true
        players = @(
            [pscustomobject]@{ username = 'TargetUser'; steamId = '76561198000000002'; online = $false; role = 'user'; lastConnection = '2026-08-01' }
            [pscustomobject]@{ username = 'OnlineUser'; steamId = '76561198000000003'; online = $true; role = 'user'; lastConnection = '2026-09-01' }
            [pscustomobject]@{ username = 'HistoryUser'; steamId = '76561198000000004'; online = $false; role = 'user'; lastConnection = '2026-07-01' }
        )
    }
}

New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$serverProfiles = @(
    [pscustomobject]@{ id = 'one'; name = 'Server One'; serverName = 'servertest'; dataRoot = (Join-Path $testRoot 'one') },
    [pscustomobject]@{ id = 'two'; name = 'Server Two'; serverName = 'server2'; dataRoot = (Join-Path $testRoot 'two') }
)
foreach ($profile in $serverProfiles) { New-Item -ItemType Directory -Path (Join-Path $profile.dataRoot 'Lua') -Force | Out-Null }

try {
    $snapshot = [ordered]@{
        item = 'MarzGuns.AA12'
        condition = 9
        conditionMax = 10
        currentAmmoCount = 12
        modData = [ordered]@{ nested = [ordered]@{ mode = 'full-auto'; level = 3 } }
        weaponParts = @([ordered]@{ item = 'MarzGuns.AA12Drum'; condition = 8; modData = [ordered]@{ skin = 'black' } })
    }
    $template = [ordered]@{
        schema = 1
        hashVersion = 2
        templateId = 'vault-template-0123456789abcdef'
        createdMs = 1787330000000
        sourceServer = 'servertest'
        sourceUsername = 'admin'
        sourceSteamId = '76561198000000001'
        snapshotHash = 'fedcba9876543210'
        summary = [ordered]@{ item = 'MarzGuns.AA12'; customName = 'Test AA12'; condition = 9; conditionMax = 10; attachments = @('MarzGuns.AA12Drum') }
        snapshot = $snapshot
    }
    $sourcePaths = Get-AdminItemVaultProfilePaths -Profile $serverProfiles[0]
    [IO.File]::WriteAllText($sourcePaths.export, ($template | ConvertTo-Json -Depth 32 -Compress) + "`n", $utf8)

    $payload = Get-AdminItemVaultPayload -Remote 'test' -RequestedBy 'admin'
    if ($payload.templates.Count -ne 1 -or $payload.imported -ne 1) { throw 'Template import failed.' }
    if ([string]$payload.templates[0].snapshot.modData.nested.mode -cne 'full-auto') { throw 'Nested snapshot data changed during import.' }

    $grantResult = Add-AdminItemVaultGrant -Remote 'test' -RequestedBy 'admin' -Body ([pscustomobject]@{
        confirm = 'GRANT_ADMIN_VAULT_ITEM'
        serverId = 'two'
        templateId = 'vault-template-0123456789abcdef'
        targetUsername = 'TargetUser'
        targetSteamId = '76561198000000002'
        count = 2
    })
    $targetPaths = Get-AdminItemVaultProfilePaths -Profile $serverProfiles[1]
    $queueRows = @(Read-AdminItemVaultJsonLines -Path $targetPaths.import | Where-Object { $_.valid -and [string]$_.value.requestId -like 'vault-grant-*' })
    if ($queueRows.Count -ne 1 -or -not $queueRows[0].valid) { throw 'Grant queue row was not written.' }
    $queued = $queueRows[0].value
    if ([string]$queued.snapshot.modData.nested.mode -cne 'full-auto' -or [int]$queued.count -ne 2 -or [int]$queued.hashVersion -ne 2) { throw 'Grant queue changed the item snapshot or hash version.' }

    $bulkBody = [pscustomobject]@{
        confirm = 'GRANT_ADMIN_VAULT_ITEM_BULK'
        confirmedTargetCount = 3
        submissionId = '0123456789abcdef0123456789abcdef'
        targetMode = 'all-registered'
        serverId = 'two'
        templateId = 'vault-template-0123456789abcdef'
        count = 1
    }
    $bulkResult = Add-AdminItemVaultGrant -Remote 'test' -RequestedBy 'admin' -Body $bulkBody
    if ($bulkResult.targetCount -ne 3 -or $bulkResult.grants.Count -ne 3) { throw 'All-registered bulk grant did not resolve all players.' }
    $queueRows = @(Read-AdminItemVaultJsonLines -Path $targetPaths.import | Where-Object { $_.valid -and [string]$_.value.requestId -like 'vault-grant-*' })
    if ($queueRows.Count -ne 4) { throw "Bulk queue expected 4 total rows, got $($queueRows.Count)." }
    $bulkSteamIds = @($bulkResult.grants | ForEach-Object { [string]$_.targetSteamId } | Sort-Object -Unique)
    if ($bulkSteamIds.Count -ne 3 -or '76561198000000004' -notin $bulkSteamIds) { throw 'Bulk grant targets were not deduplicated from the server player directory.' }
    $duplicateResult = Add-AdminItemVaultGrant -Remote 'test' -RequestedBy 'admin' -Body $bulkBody
    $grantRowsAfterDuplicate = @(Read-AdminItemVaultJsonLines -Path $targetPaths.import | Where-Object { $_.valid -and [string]$_.value.requestId -like 'vault-grant-*' })
    if (-not $duplicateResult.duplicate -or $grantRowsAfterDuplicate.Count -ne 4) { throw 'Submission id did not prevent duplicate bulk queue writes.' }
    try {
        [void](Add-AdminItemVaultGrant -Remote 'test' -RequestedBy 'admin' -Body ([pscustomobject]@{
            confirm = 'GRANT_ADMIN_VAULT_ITEM_BULK'; confirmedTargetCount = 2; targetMode = 'all-registered'
            serverId = 'two'; templateId = 'vault-template-0123456789abcdef'; count = 1
        }))
        throw 'Changed target count was accepted.'
    }
    catch {
        if ($_.Exception.Message -eq 'Changed target count was accepted.') { throw }
        if ($_.Exception.Message -notmatch '人数已变化') { throw }
    }

    $receipt = [ordered]@{ schema = 1; requestId = $grantResult.grant.requestId; status = 'queued_offline'; detail = 'waiting_for_player'; delivered = 0; updatedMs = 1787330000500 }
    Add-AdminItemVaultJsonLine -Path $targetPaths.receipt -Value $receipt
    $receiptPayload = Get-AdminItemVaultReceiptPayload -RequestId $grantResult.grant.requestId
    if ([string]$receiptPayload.grant.status -cne 'queued_offline') { throw 'Receipt state was not synchronized.' }
    $batchReceipt = Get-AdminItemVaultReceiptBatchPayload -Body ([pscustomobject]@{ requestIds = @($grantResult.grant.requestId, $bulkResult.grants[0].requestId) })
    if ($batchReceipt.requested -ne 2 -or $batchReceipt.found -ne 2) { throw 'Batch receipt lookup did not return requested grants.' }

    [void](Remove-AdminItemVaultTemplate -Remote 'test' -RequestedBy 'admin' -Body ([pscustomobject]@{
        confirm = 'DELETE_ADMIN_VAULT_TEMPLATE'
        templateId = 'vault-template-0123456789abcdef'
    }))
    $store = Read-AdminItemVaultStore
    $store.sourceCursors = @()
    Save-AdminItemVaultStore -Store $store
    $afterDelete = Get-AdminItemVaultPayload -Remote 'test' -RequestedBy 'admin'
    if ($afterDelete.templates.Count -ne 0) { throw 'Deleted template was re-imported.' }
    if (-not ($auditRecords | Where-Object action -ceq 'admin-item-vault-grant')) { throw 'Grant audit record is missing.' }

    [pscustomobject]@{
        ok = $true
        imported = 1
        queuedCopies = 2
        bulkTargets = 3
        duplicatePrevented = $true
        changedRosterRejected = $true
        receipt = 'queued_offline'
        deletedTemplateStayedDeleted = $true
        auditRecords = $auditRecords.Count
    } | ConvertTo-Json
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
