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
    'Get-AdminItemVaultProfilePaths', 'Read-AdminItemVaultJsonLines', 'Add-AdminItemVaultJsonLine',
    'Test-AdminItemVaultTemplateRecord', 'Import-AdminItemVaultTemplates', 'Sync-AdminItemVaultReceipts',
    'Get-AdminItemVaultPayload', 'Invoke-AdminItemVaultSync', 'Add-AdminItemVaultGrant', 'Remove-AdminItemVaultTemplate',
    'Get-AdminItemVaultReceiptPayload'
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
        players = @([pscustomobject]@{ username = 'TargetUser'; steamId = '76561198000000002'; online = $false; role = 'user' })
    }
}

New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$serverProfiles = @(
    [pscustomobject]@{ id = 'one'; name = 'Server One'; serverName = 'servertest'; dataRoot = (Join-Path $testRoot 'one') },
    [pscustomobject]@{ id = 'two'; name = 'Server Two'; serverName = 'server2'; dataRoot = (Join-Path $testRoot 'two') }
)
foreach ($profile in $serverProfiles) { New-Item -ItemType Directory -Path (Join-Path $profile.dataRoot 'Lua') -Force | Out-Null }
$processedSyncRequests = @{}

function Start-Sleep {
    param([int]$Milliseconds)
    foreach ($profile in $script:serverProfiles) {
        $paths = Get-AdminItemVaultProfilePaths -Profile $profile
        foreach ($row in @(Read-AdminItemVaultJsonLines -Path $paths.import)) {
            if (-not $row.valid -or [string]$row.value.kind -cne 'sync') { continue }
            $requestId = [string]$row.value.requestId
            if ($script:processedSyncRequests[$requestId]) { continue }
            Add-AdminItemVaultJsonLine -Path $paths.receipt -Value ([ordered]@{
                schema = 1; kind = 'sync'; requestId = $requestId; status = 'synced'
                detail = 'attempted=1;completed=1;failed=0;remaining=0'; delivered = 1
                updatedMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            })
            $script:processedSyncRequests[$requestId] = $true
        }
    }
}

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

    $payload = Invoke-AdminItemVaultSync -Remote 'test' -RequestedBy 'admin' -WaitMilliseconds 1000
    if ($payload.templates.Count -ne 1 -or $payload.imported -ne 1) { throw 'Template import failed.' }
    if ($payload.sync.synced -ne 2 -or $payload.sync.failed -ne 0) { throw 'Triggered server synchronization failed.' }
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
    $queueRows = @(Read-AdminItemVaultJsonLines -Path $targetPaths.import | Where-Object {
        $_.valid -and [string]$_.value.requestId -ceq [string]$grantResult.grant.requestId
    })
    if ($queueRows.Count -ne 1 -or -not $queueRows[0].valid) { throw 'Grant queue row was not written.' }
    $queued = $queueRows[0].value
    if ([string]$queued.snapshot.modData.nested.mode -cne 'full-auto' -or [int]$queued.count -ne 2 -or [int]$queued.hashVersion -ne 2) { throw 'Grant queue changed the item snapshot or hash version.' }

    $receipt = [ordered]@{ schema = 1; requestId = $grantResult.grant.requestId; status = 'queued_offline'; detail = 'waiting_for_player'; delivered = 0; updatedMs = 1787330000500 }
    Add-AdminItemVaultJsonLine -Path $targetPaths.receipt -Value $receipt
    $receiptPayload = Get-AdminItemVaultReceiptPayload -RequestId $grantResult.grant.requestId
    if ([string]$receiptPayload.grant.status -cne 'queued_offline') { throw 'Receipt state was not synchronized.' }

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
        receipt = 'queued_offline'
        deletedTemplateStayedDeleted = $true
        auditRecords = $auditRecords.Count
    } | ConvertTo-Json
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
