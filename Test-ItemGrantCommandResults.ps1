param()

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
$utf8 = [Text.UTF8Encoding]::new($false)
$commandRequests = @{}
$logReadCount = 0
$fixtureLogPayload = $null
$receiptRoot = Join-Path $env:TEMP ("pz-item-result-test-" + [guid]::NewGuid().ToString('N'))

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

foreach ($name in @('Get-AddItemCommandParts', 'Get-AddItemOutcomeMap', 'Get-CommandResultPayload', 'Get-CommandResultsPayload', 'Get-CommandSubmissionPayload')) {
    Import-PanelFunction -Name $name
}

function Get-ManagedProfilePaths {
    param([string]$Id)
    return [pscustomobject]@{ receiptDir = $script:receiptRoot }
}

function Get-LogPayload {
    param($Profile, [long]$After)
    $script:logReadCount += 1
    return $script:fixtureLogPayload
}

New-Item -ItemType Directory -Path $receiptRoot -Force | Out-Null
try {
    $entries = @()
    $lines = [Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt 45; $index += 1) {
        $id = '{0:x32}' -f ($index + 1)
        $username = 'Player{0:d2}' -f $index
        $command = "additem `"$username`" `"Base.MoneyBundle`" 3"
        $entry = [pscustomobject]@{ id = $id; command = $command }
        $entries += $entry
        $commandRequests[$id] = [pscustomobject]@{
            serverId = 'mock'; action = 'additem'; command = $command
            queuedAt = (Get-Date).ToString('o'); logCursor = 123L
        }
        [IO.File]::WriteAllText((Join-Path $receiptRoot "$id.json"), ([ordered]@{
            id = $id; command = $command; status = 'completed'; confirmation = 'stdin-flushed'
        } | ConvertTo-Json), $utf8)
        $lines.Add("LOG : General > command entered via server console (System.in): `"$command`"")
    }

    for ($noise = 0; $noise -lt 90; $noise += 1) {
        $lines.Add("LOG : Lua > [PZAI_EVENT] noise-$noise")
    }
    for ($index = 0; $index -lt 45; $index += 1) {
        if ($index -in @(7, 31)) {
            $lines.Add('LOG : General > No such user.')
        }
        else {
            $username = 'Player{0:d2}' -f $index
            $lines.Add("LOG : General > Item Base.MoneyBundle Added in $username's inventory.")
        }
        $lines.Add("WARN : Animation > unrelated-$index")
    }
    $fixtureLogPayload = @{ text = ($lines -join "`n"); cursor = 999999L; reset = $false }

    $outcomes = Get-AddItemOutcomeMap -Entries $entries -Lines $lines
    $successCount = @($outcomes.Values | Where-Object status -eq 'success').Count
    $failureCount = @($outcomes.Values | Where-Object status -eq 'failed').Count
    if ($outcomes.Count -ne 45 -or $successCount -ne 43 -or $failureCount -ne 2) {
        throw "Unexpected parser totals: all=$($outcomes.Count), success=$successCount, failed=$failureCount"
    }
    if ([string]$outcomes[$entries[7].id].resultCode -ne 'player-not-found' -or [string]$outcomes[$entries[31].id].resultCode -ne 'player-not-found') {
        throw 'No-such-user results were not assigned to the corresponding queued players.'
    }

    $profile = [pscustomobject]@{ id = 'mock'; consoleLog = Join-Path $receiptRoot 'server-console.txt' }
    [IO.File]::WriteAllText($profile.consoleLog, 'fixture', $utf8)
    $batch = Get-CommandResultsPayload -Profile $profile -Ids @($entries.id)
    if ($logReadCount -ne 1) { throw "Batch result read the shared log $logReadCount times instead of once." }
    if ($batch.results.Count -ne 45) { throw "Batch returned $($batch.results.Count) results instead of 45." }
    $confirmed = @($batch.results | Where-Object { $_.done -and $_.gameStatus -eq 'success' -and $_.resultCode -eq 'item-added' })
    $failed = @($batch.results | Where-Object { $_.done -and $_.gameStatus -eq 'failed' -and $_.resultCode -eq 'player-not-found' })
    if ($confirmed.Count -ne 43 -or $failed.Count -ne 2) {
        throw "Unexpected batch totals: confirmed=$($confirmed.Count), failed=$($failed.Count)"
    }
    if (@($batch.results | Where-Object { @($_.output).Count -gt 2 }).Count -gt 0) {
        throw 'Command results retained unrelated high-volume log lines.'
    }

    $unconfirmedId = 'f0000000000000000000000000000000'
    $unconfirmedCommand = 'additem "MissingResult" "Base.Money" 1'
    $commandRequests[$unconfirmedId] = [pscustomobject]@{
        serverId = 'mock'; action = 'additem'; command = $unconfirmedCommand
        queuedAt = (Get-Date).AddSeconds(-13).ToString('o'); logCursor = 123L
    }
    [IO.File]::WriteAllText((Join-Path $receiptRoot "$unconfirmedId.json"), ([ordered]@{
        id = $unconfirmedId; command = $unconfirmedCommand; status = 'completed'; confirmation = 'stdin-flushed'
    } | ConvertTo-Json), $utf8)
    $emptyPayload = @{ text = "LOG : General > command entered via server console (System.in): `"$unconfirmedCommand`"`nLOG : Lua > [PZAI_EVENT] result-line-was-lost"; cursor = 1000000L; reset = $false }
    $unconfirmed = Get-CommandResultPayload -Profile $profile -Id $unconfirmedId -SharedLogPayload $emptyPayload
    if (-not $unconfirmed.done -or $unconfirmed.gameStatus -ne 'unconfirmed' -or $unconfirmed.resultCode -ne 'item-result-unconfirmed') {
        throw 'A delivered command without a captured game result did not settle as unconfirmed.'
    }

    $commandRequests.Remove($unconfirmedId)
    $recovered = Get-CommandResultPayload -Profile $profile -Id $unconfirmedId -SharedLogPayload $null
    if (-not $recovered.done -or $recovered.gameStatus -ne 'unconfirmed' -or $recovered.resultCode -ne 'item-result-unconfirmed') {
        throw 'An additem receipt recovered after a panel restart was not marked unconfirmed.'
    }

    $submissionId = 'abc00000000000000000000000000000'
    $executionHistory = @([pscustomobject]@{
        id = 'history-1'; serverId = 'mock'; clientRequestId = $submissionId; action = 'additem'; status = 'success'
        resultCode = 'completed'; message = 'confirmed'; requestIds = @($entries.id); auxiliaryRequestIds = @(); noticeId = ''
        createdAt = (Get-Date).AddSeconds(-2).ToString('o'); updatedAt = (Get-Date).ToString('o')
    })
    $submission = Get-CommandSubmissionPayload -Profile $profile -Id $submissionId
    if (-not $submission.found -or $submission.itemRequestIds.Count -ne 45 -or $submission.targetCount -ne 45) {
        throw 'The recoverable command submission payload did not preserve its item request IDs.'
    }

    [pscustomobject]@{
        ok = $true
        targets = $batch.results.Count
        confirmed = $confirmed.Count
        failed = $failed.Count
        logReads = $logReadCount
        maxOutputLines = (@($batch.results | ForEach-Object { @($_.output).Count } | Measure-Object -Maximum).Maximum)
        missingResultStatus = $unconfirmed.gameStatus
    } | ConvertTo-Json
}
finally {
    Remove-Item -LiteralPath $receiptRoot -Recurse -Force -ErrorAction SilentlyContinue
}
