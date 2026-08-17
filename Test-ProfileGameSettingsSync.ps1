$ErrorActionPreference = "Stop"
$projectRoot = $PSScriptRoot
$panelScript = Join-Path $projectRoot "PZ-ControlPanel.ps1"
$utf8 = [Text.UTF8Encoding]::new($false)

$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($panelScript, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw ($errors | Out-String) }

foreach ($name in @("Get-TextFileEncoding", "Set-PZIniSettings", "Sync-PZProfileGameSettings", "Read-PZIniSettings", "Get-PZSaveBackupPayload", "Set-PZSaveBackupSettings")) {
    $functionAst = $ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true) | Select-Object -First 1
    if (-not $functionAst) { throw "Missing function: $name" }
    Invoke-Expression $functionAst.Extent.Text
}

$testBase = [IO.Path]::GetFullPath((Join-Path $projectRoot ".tmp"))
$testRoot = Join-Path $testBase "profile-settings-sync-test"
$resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
if (-not $resolvedTestRoot.StartsWith($testBase, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Test directory is outside the expected root."
}

Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path (Join-Path $resolvedTestRoot "Server") -Force | Out-Null
try {
    $iniPath = Join-Path $resolvedTestRoot "Server\test.ini"
    [IO.File]::WriteAllText(
        $iniPath,
        "DefaultPort=1`r`nUDPPort=2`r`nMaxPlayers=3`r`nSaveWorldEveryMinutes=0`r`nBackupsPeriod=60`r`nBackupsCount=3`r`n",
        $utf8
    )
    $profile = [pscustomobject]@{
        id = "test"
        dataRoot = $resolvedTestRoot
        serverName = "test"
        ports = @(16261, 16262)
        maxPlayers = 100
    }

    $result = Sync-PZProfileGameSettings -Profile $profile
    $actual = @(
        Get-Content -LiteralPath $iniPath -Encoding UTF8 |
            Select-String -Pattern "^(DefaultPort|UDPPort|MaxPlayers)=" |
            ForEach-Object { [string]$_ }
    )
    $expected = @("DefaultPort=16261", "UDPPort=16262", "MaxPlayers=100")
    if (($actual -join "|") -cne ($expected -join "|")) {
        throw "Unexpected sync result: $($actual -join ', ')"
    }
    if (-not $result.updated -or -not (Test-Path -LiteralPath "$iniPath.web-panel.bak")) {
        throw "Sync result or backup state is invalid."
    }

    $saveBackupResult = Set-PZIniSettings -Path $iniPath -Settings ([ordered]@{
        SaveWorldEveryMinutes = 10
        BackupsPeriod = 120
        BackupsCount = 5
    })
    $saveBackupValues = @(
        Get-Content -LiteralPath $iniPath -Encoding UTF8 |
            Select-String -Pattern "^(SaveWorldEveryMinutes|BackupsPeriod|BackupsCount)=" |
            ForEach-Object { [string]$_ }
    )
    $expectedSaveBackup = @("SaveWorldEveryMinutes=10", "BackupsPeriod=120", "BackupsCount=5")
    if (($saveBackupValues -join "|") -cne ($expectedSaveBackup -join "|")) {
        throw "Unexpected save/backup values: $($saveBackupValues -join ', ')"
    }
    $periodDirectory = Join-Path $resolvedTestRoot "backups\period"
    New-Item -ItemType Directory -Path $periodDirectory -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $periodDirectory "backup_old.zip"), [byte[]]::new(10))
    Start-Sleep -Milliseconds 20
    [IO.File]::WriteAllBytes((Join-Path $periodDirectory "backup_new.zip"), [byte[]]::new(20))
    $payload = Get-PZSaveBackupPayload -Profile $profile
    if (-not $payload.autoSaveEnabled -or $payload.saveIntervalMinutes -ne 10 -or -not $payload.autoBackupEnabled -or $payload.backupIntervalMinutes -ne 120 -or $payload.backupCount -ne 5) {
        throw "Save/backup payload did not reflect INI settings."
    }
    if ($payload.backupFileCount -ne 2 -or $payload.backupTotalBytes -ne 30 -or $payload.latestBackupName -ne "backup_new.zip" -or -not $payload.nextBackupAt) {
        throw "Backup directory status is incorrect."
    }

    [void](Set-PZIniSettings -Path $iniPath -Settings ([ordered]@{
        SaveWorldEveryMinutes = 0
        BackupsPeriod = 0
        BackupsCount = 5
    }))
    $disabledText = [IO.File]::ReadAllText($iniPath, $utf8)
    if ($disabledText -notmatch "(?m)^SaveWorldEveryMinutes=0`r?$" -or $disabledText -notmatch "(?m)^BackupsPeriod=0`r?$") {
        throw "Disabled plans were not persisted as zero."
    }
    if ($disabledText -match "(?<!`r)`n") { throw "CRLF line endings were not preserved." }
    $finalBytes = [IO.File]::ReadAllBytes($iniPath)
    if ($finalBytes.Length -ge 3 -and $finalBytes[0] -eq 0xEF -and $finalBytes[1] -eq 0xBB -and $finalBytes[2] -eq 0xBF) {
        throw "UTF-8 BOM state was not preserved."
    }
    if (-not $saveBackupResult.updated) { throw "Save/backup settings update failed." }

    function Get-ServerState { return [pscustomobject]@{ alive = $false; writable = $false } }
    function Add-Audit { param($Remote, $Action, $Detail, $Result) }
    function Add-ExecutionHistoryRecord {
        param($ServerId, $Category, $Action, $Source, $Summary, $Status, $Message, $RequestIds, $Detail)
        return $null
    }
    $commandRequests = @{}
    $settingsPayload = Set-PZSaveBackupSettings -Profile $profile -AutoSaveEnabled $true -SaveIntervalMinutes 15 `
        -AutoBackupEnabled $true -BackupIntervalMinutes 180 -BackupCount 7 -Remote "test"
    if (-not $settingsPayload.ok -or $settingsPayload.saveIntervalMinutes -ne 15 -or $settingsPayload.backupIntervalMinutes -ne 180 -or $settingsPayload.backupCount -ne 7) {
        throw "Set-PZSaveBackupSettings returned an invalid payload."
    }
    $activationMessage = [string]$settingsPayload["message"]
    if ([string]::IsNullOrWhiteSpace($activationMessage) -or @($settingsPayload["runtimeRequestIds"]).Count -ne 0) {
        throw "Stopped-server activation state is invalid."
    }

    [pscustomobject]@{
        Passed = $true
        Values = $actual -join ", "
        SaveBackupValues = $saveBackupValues -join ", "
        DisabledValues = "SaveWorldEveryMinutes=0, BackupsPeriod=0"
        EncodingAndNewlinesPreserved = $true
        SettingsApiPayload = "15 minute save, 180 minute backup, 7 retained"
        BackupCreated = $true
    } | Format-List
}
finally {
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}
