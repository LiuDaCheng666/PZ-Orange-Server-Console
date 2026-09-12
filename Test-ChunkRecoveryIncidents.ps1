param()

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
$testRoot = Join-Path $env:TEMP ("PZChunkRecoveryIncidents-" + [guid]::NewGuid().ToString('N'))
$script:chunkRecoveryRoot = Join-Path $testRoot 'chunk-recovery'
$script:utf8 = [Text.UTF8Encoding]::new($false)
$script:pythonRuntimePath = 'C:\Users\Administrator\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
$script:chunkRecoveryToolPath = Join-Path $projectRoot 'tools\PZChunkRecovery\pz_chunk_recovery.py'

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
    'Get-ChunkRecoveryPaths', 'Read-MapResetJson', 'Write-MapResetJson',
    'ConvertFrom-ChunkRecoveryCrcLogText', 'Get-ChunkRecoveryIncidentSafehouses',
    'Update-ChunkRecoveryRuntimeIncidents', 'Update-ChunkRecoveryIncidentRecommendations'
)) { Import-PanelFunction -Name $name }

try {
    $logPath = Join-Path $testRoot 'server-console.txt'
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $profile = [pscustomobject]@{ id = 'test'; consoleLog = $logPath; dataRoot = $testRoot }
    $serverState = [pscustomobject]@{ startedAt = '2026-08-27T10:45:00+08:00' }
    $safehouse = [pscustomobject]@{
        id = 'safehouse-1'; title = 'Test Home'; owner = 'owner'; players = @('member')
        chunks = @([pscustomobject]@{ wx = 1261; wy = 833 })
    }
    $first = "ERROR: General f:1 st:1> IsoChunk.LoadOrCreate> Exception thrown`r`njava.lang.RuntimeException`r`nCRC mismatch save=2145607001 load=1209181305`r`nload wx"
    [IO.File]::WriteAllText($logPath, $first, $utf8)
    $state = Update-ChunkRecoveryRuntimeIncidents -Profile $profile -ServerState $serverState -Safehouses @($safehouse)
    if (@($state.incidents).Count -ne 0) { throw 'A partial CRC record was emitted too early.' }

    [IO.File]::AppendAllText($logPath, ",wy=1261,833 thread=`"LoadChunk`"`r`n", $utf8)
    $state = Update-ChunkRecoveryRuntimeIncidents -Profile $profile -ServerState $serverState -Safehouses @($safehouse)
    if (@($state.incidents).Count -ne 1) { throw 'The split CRC record was not captured exactly once.' }
    $incident = @($state.incidents)[0]
    if ([int]$incident.wx -ne 1261 -or [int]$incident.wy -ne 833 -or [int64]$incident.frame -ne 1) { throw 'CRC coordinates or frame were parsed incorrectly.' }
    if (@($incident.safehouses).Count -ne 1 -or [string]$incident.safehouses[0].owner -cne 'owner') { throw 'Safehouse mapping failed.' }

    $duplicate = "CRC mismatch save=2145607001 load=1209181305`r`nMessage: Error loading chunk 1261,833`r`n"
    [IO.File]::AppendAllText($logPath, $duplicate, $utf8)
    $state = Update-ChunkRecoveryRuntimeIncidents -Profile $profile -ServerState $serverState -Safehouses @($safehouse)
    if (@($state.incidents).Count -ne 1) { throw 'A duplicate CRC incident was persisted.' }

    $backup = Join-Path $testRoot 'before-start.zip'
    $zipScript = 'import struct,sys,zipfile,zlib; body=b"healthy"; payload=b"\0"+struct.pack(">IIQ",249,17+len(body),zlib.crc32(body)&0xffffffff)+body; z=zipfile.ZipFile(sys.argv[1],"w",allowZip64=True); z.writestr("Saves/Multiplayer/test/map/1261/833.bin",payload); z.close()'
    & $pythonRuntimePath -c $zipScript $backup
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create recommendation fixture.' }
    $before = [pscustomobject]@{ id = 'before'; name = 'before-start.zip'; path = $backup; bytes = (Get-Item $backup).Length; modifiedAt = '2026-08-27T09:00:00+08:00'; source = 'period' }
    $after = [pscustomobject]@{ id = 'after'; name = 'after-start.zip'; path = $backup; bytes = (Get-Item $backup).Length; modifiedAt = '2026-08-27T11:00:00+08:00'; source = 'period' }
    $state = Update-ChunkRecoveryIncidentRecommendations -Profile ([pscustomobject]@{ id = 'test'; serverName = 'test'; dataRoot = $testRoot }) -IncidentState $state -Backups @($after, $before)
    $incident = @($state.incidents)[0]
    if ([string]$incident.recommendedBackup.id -cne 'before') { throw 'Startup incident did not exclude post-start backups.' }
    $moved = [pscustomobject]@{ id = 'moved'; name = 'backup_4.zip'; path = $backup; bytes = $before.bytes; modifiedAt = $before.modifiedAt; source = 'period' }
    $state = Update-ChunkRecoveryIncidentRecommendations -Profile ([pscustomobject]@{ id = 'test'; serverName = 'test'; dataRoot = $testRoot }) -IncidentState $state -Backups @($after, $moved)
    if ([string]$state.incidents[0].recommendedBackup.id -cne 'moved') { throw 'A rotated backup was not tracked by timestamp and size.' }

    [pscustomobject]@{
        ok = $true
        splitRecordCaptured = $true
        duplicateSuppressed = $true
        safehouseMapped = $true
        preStartupBackupRecommended = $true
        rotatedBackupTracked = $true
        incident = "$($incident.wx),$($incident.wy)"
    } | ConvertTo-Json
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
