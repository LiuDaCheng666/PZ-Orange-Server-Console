param()

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
$utf8 = [Text.UTF8Encoding]::new($false)
$commandRequests = @{}
$logReadCount = 0
$fixtureLogPayload = $null
$fixtureLogPayloadQueue = [Collections.Generic.Queue[object]]::new()
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

foreach ($name in @('Get-LogPayload', 'Get-AddItemCommandParts', 'New-AddItemOutcomeState', 'Update-AddItemOutcomeState', 'Get-AddItemOutcomeMap', 'Invoke-AddItemLogScan', 'Get-CommandResultPayload', 'Get-CommandResultsPayload', 'Get-CommandSubmissionPayload', 'Wait-ItemGrantSubmissionResult')) {
    Import-PanelFunction -Name $name
}
$actualGetLogPayload = ${function:Get-LogPayload}

function Get-ManagedProfilePaths {
    param([string]$Id)
    return [pscustomobject]@{ receiptDir = $script:receiptRoot }
}

function Get-LogPayload {
    param($Profile, [long]$After, [switch]$PreserveFromCursor, [int]$MaxBytes = 262144)
    $script:logReadCount += 1
    if ($script:fixtureLogPayloadQueue.Count -gt 0) { return $script:fixtureLogPayloadQueue.Dequeue() }
    return $script:fixtureLogPayload
}
$fixtureGetLogPayload = ${function:Get-LogPayload}

New-Item -ItemType Directory -Path $receiptRoot -Force | Out-Null
try {
    $realLogPath = Join-Path $receiptRoot 'large-console.txt'
    $realCommand = 'additem "LargeLogPlayer" "Base.Money" 1'
    $largeNoise = ('LOG : Lua > high-volume-noise-' + ('x' * 220) + "`n") * 13000
    $realLogText = "LOG : General > command entered via server console (System.in): `"$realCommand`"`n$largeNoise" + "LOG : General > Item Base.Money Added in LargeLogPlayer's inventory.`n"
    [IO.File]::WriteAllText($realLogPath, $realLogText, $utf8)
    Set-Item -LiteralPath Function:\script:Get-LogPayload -Value $actualGetLogPayload
    $realProfile = [pscustomobject]@{ consoleLog = $realLogPath }
    $realState = New-AddItemOutcomeState -Entries @([pscustomobject]@{ id = 'e0000000000000000000000000000000'; command = $realCommand })
    $realReads = 0
    do {
        $chunk = Get-LogPayload -Profile $realProfile -After ([long]$realState.cursor) -PreserveFromCursor -MaxBytes 262144
        [void](Update-AddItemOutcomeState -State $realState -Text ([string]$chunk.text) -CompleteChunk (-not [bool]$chunk.hasMore))
        $realState.cursor = [long]$chunk.cursor
        $realReads += 1
    } while ($chunk.hasMore -and $realReads -lt 64)
    if ($realReads -le 1 -or [string]$realState.outcomes['e0000000000000000000000000000000'].status -ne 'success') {
        throw 'The preserved multi-megabyte log scan did not retain the command until its success result.'
    }
    Set-Item -LiteralPath Function:\script:Get-LogPayload -Value $fixtureGetLogPayload

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

    $readsAfterBatch = $logReadCount
    $fixtureLogPayload = @{ text = 'LOG : Lua > the log continued after all item results'; cursor = 1200000L; reset = $false; hasMore = $false }
    $cachedBatch = Get-CommandResultsPayload -Profile $profile -Ids @($entries.id)
    if ($logReadCount -ne $readsAfterBatch -or @($cachedBatch.results | Where-Object gameStatus -eq 'success').Count -ne 43) {
        throw 'Cached terminal item results changed or reread the log after it continued growing.'
    }

    $duplicateIds = @('d0000000000000000000000000000001', 'd0000000000000000000000000000002')
    $duplicateCommand = 'additem "RepeatedPlayer" "Base.Money" 1'
    $duplicateEntries = @()
    foreach ($duplicateId in $duplicateIds) {
        $duplicateEntries += [pscustomobject]@{ id = $duplicateId; command = $duplicateCommand }
        $commandRequests[$duplicateId] = [pscustomobject]@{
            serverId = 'mock'; action = 'additem'; command = $duplicateCommand
            queuedAt = (Get-Date).ToString('o'); logCursor = 500L
        }
    }
    $enteredLine = "LOG : General > command entered via server console (System.in): `"$duplicateCommand`""
    $splitAt = [math]::Floor($enteredLine.Length / 2)
    $fixtureLogPayloadQueue.Enqueue(@{
        text = $enteredLine + "`n" + $enteredLine.Substring(0, $splitAt)
        cursor = 4194804L; reset = $false; hasMore = $true; length = 8389108L
    })
    $fixtureLogPayloadQueue.Enqueue(@{
        text = $enteredLine.Substring($splitAt) + "`nLOG : General > Item Base.Money Added in RepeatedPlayer's inventory.`nLOG : General > Item Base.Money Added in RepeatedPlayer's inventory.`n"
        cursor = 8389108L; reset = $false; hasMore = $false; length = 8389108L
    })
    $firstSegment = Invoke-AddItemLogScan -Profile $profile -Entries $duplicateEntries -MaxSegments 1
    if (-not $firstSegment.hasMore -or [string]$firstSegment.outcomes[$duplicateIds[0]].status -ne 'pending' -or $firstSegment.outcomes.ContainsKey($duplicateIds[1])) {
        throw 'The first segmented scan did not preserve its pending command and split-line carry state.'
    }
    $secondSegment = Invoke-AddItemLogScan -Profile $profile -Entries $duplicateEntries -MaxSegments 1
    if ($secondSegment.hasMore -or @($duplicateIds | Where-Object { [string]$secondSegment.outcomes[$_].status -eq 'success' }).Count -ne 2) {
        throw 'Repeated additem commands were not matched in queue order across log segments.'
    }
    $readsAfterDuplicate = $logReadCount
    [void](Invoke-AddItemLogScan -Profile $profile -Entries $duplicateEntries -MaxSegments 1)
    if ($logReadCount -ne $readsAfterDuplicate) { throw 'A completed segmented scan reread the log instead of using cached outcomes.' }

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

    Set-Item -LiteralPath Function:\script:Get-CommandResultsPayload -Value {
        return [ordered]@{ ok = $true; results = @([ordered]@{ done = $true; gameStatus = 'success'; resultCode = 'item-added' }) }
    }
    Set-Item -LiteralPath Function:\script:Invoke-ExecutionHistoryTick -Value { }
    Set-Item -LiteralPath Function:\script:Get-CommandSubmissionPayload -Value {
        return [ordered]@{ ok = $true; found = $true; status = 'success'; resultCode = 'completed'; resultMessage = 'confirmed'; targetCount = 1 }
    }
    $immediate = Wait-ItemGrantSubmissionResult -Profile $profile -SubmissionId $submissionId -RequestIds @('abc00000000000000000000000000001') -TimeoutMilliseconds 500
    if (-not $immediate.settled -or [string]$immediate.submission.status -ne 'success' -or [string]$immediate.results[0].gameStatus -ne 'success') {
        throw 'The command POST immediate item result did not include the terminal game result and persisted submission.'
    }

    [pscustomobject]@{
        ok = $true
        targets = $batch.results.Count
        confirmed = $confirmed.Count
        failed = $failed.Count
        logReads = $logReadCount
        realLogBytes = ([IO.FileInfo]$realLogPath).Length
        realLogReads = $realReads
        segmentedDuplicateResults = 2
        immediatePostResult = [string]$immediate.submission.status
        maxOutputLines = (@($batch.results | ForEach-Object { @($_.output).Count } | Measure-Object -Maximum).Maximum)
        missingResultStatus = $unconfirmed.gameStatus
    } | ConvertTo-Json
}
finally {
    Remove-Item -LiteralPath $receiptRoot -Recurse -Force -ErrorAction SilentlyContinue
}
