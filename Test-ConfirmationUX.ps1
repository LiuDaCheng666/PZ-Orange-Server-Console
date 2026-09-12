param()

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$html = Get-Content -LiteralPath (Join-Path $root "web\index.html") -Raw -Encoding UTF8
$javascript = Get-Content -LiteralPath (Join-Path $root "web\app.js") -Raw -Encoding UTF8

$removedElementIds = @(
    "confirmSteamId",
    "mapResetConfirmation",
    "mapResetRollbackConfirmation",
    "chunkRecoveryConfirmation",
    "chunkRollbackConfirmation"
)
foreach ($id in $removedElementIds) {
    if ($html -match [regex]::Escape($id)) {
        throw "Typed confirmation element is still referenced: $id"
    }
}
foreach ($id in $removedElementIds | Where-Object { $_ -ne "confirmSteamId" }) {
    if ($javascript -match [regex]::Escape($id)) {
        throw "Removed typed confirmation control is still referenced by JavaScript: $id"
    }
}
if ($html -match '输入\s*(目标 SteamID|serverName).{0,12}确认' -or $javascript -match 'prompt\(') {
    throw "A manual typed-operation confirmation is still present."
}

$requiredPayloads = @(
    'confirmSteamId:steamId',
    "confirmation:data.serverName",
    "confirmation='RECHECK_ALL'",
    "confirm:'RESTART_PHYSICAL_HOST'"
)
foreach ($payload in $requiredPayloads) {
    if ($javascript -notmatch [regex]::Escape($payload)) {
        throw "Internal safety token is missing: $payload"
    }
}
if ($javascript -notmatch 'confirm\(`永久删除 SteamID' -or
        $javascript -notmatch '最终确认：对.*创建完整存档备份' -or
        $javascript -notmatch '最终确认：从.*恢复区块' -or
        $javascript -notmatch '确认撤销所选定点恢复事务' -or
        $javascript -notmatch '确认继续执行全量重检并生成' -or
        $javascript -notmatch '确认全部游戏服务器均已保存并停止') {
    throw "One or more dangerous operations no longer have a click confirmation dialog."
}

[pscustomobject]@{
    ok = $true
    typedOperationConfirmations = 0
    clickConfirmationsPreserved = $true
    internalSafetyTokensPreserved = $true
} | ConvertTo-Json
