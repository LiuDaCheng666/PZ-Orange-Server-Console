param(
    [ValidateSet("status", "players", "system", "audit", "command", "start", "stop", "restart", "operation")]
    [string]$Action = "status",
    [string]$PanelUrl = $(if ($env:PZ_PANEL_URL) { $env:PZ_PANEL_URL } else { "http://127.0.0.1:8790" }),
    [string]$Username = $env:PZ_PANEL_USERNAME,
    [securestring]$Password,
    [string]$ServerId,
    [string]$CommandBodyJson,
    [string]$OperationId,
    [switch]$ConfirmAction,
    [switch]$AllowOnlinePlayers,
    [ValidateRange(5, 900)]
    [int]$TimeoutSeconds = 180
)

$ErrorActionPreference = "Stop"
$PanelUrl = $PanelUrl.TrimEnd('/')
$webSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
$csrf = $null
$plainPassword = $null

function Invoke-PanelApi {
    param([string]$Method, [string]$Path, $Body)
    $parameters = @{
        Uri = "$PanelUrl$Path"
        Method = $Method
        WebSession = $webSession
        UseBasicParsing = $true
        ErrorAction = "Stop"
    }
    if ($Method -ne "GET") {
        $parameters.ContentType = "application/json; charset=utf-8"
        if ($csrf) { $parameters.Headers = @{ "X-PZ-CSRF" = $csrf } }
        if ($null -ne $Body) { $parameters.Body = $Body | ConvertTo-Json -Depth 12 -Compress }
    }
    try {
        return (Invoke-WebRequest @parameters).Content | ConvertFrom-Json
    }
    catch {
        $message = $_.Exception.Message
        if ($_.Exception.Response) {
            try {
                $reader = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())
                try {
                    $errorPayload = $reader.ReadToEnd() | ConvertFrom-Json
                    if ($errorPayload.error) { $message = [string]$errorPayload.error }
                }
                finally { $reader.Dispose() }
            }
            catch { }
        }
        throw $message
    }
}

function Get-SelectedServer {
    param($Status)
    $servers = @($Status.servers)
    if ($ServerId) {
        $selected = $servers | Where-Object { [string]$_.id -ceq $ServerId } | Select-Object -First 1
        if (-not $selected) { throw "Server ID '$ServerId' was not found. Available: $($servers.id -join ', ')" }
        return $selected
    }
    if ($servers.Count -eq 1) { return $servers[0] }
    throw "Specify -ServerId. Available: $($servers.id -join ', ')"
}

function Assert-WriteConfirmed {
    if (-not $ConfirmAction) { throw "Action '$Action' requires -ConfirmAction." }
}

function Wait-CommandResults {
    param($Response, [string]$SelectedServerId)
    $ids = if (@($Response.requestIds).Count) { @($Response.requestIds) } else { @([string]$Response.requestId) }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $results = @{}
    do {
        foreach ($id in $ids) {
            if (-not $results.ContainsKey($id) -or -not [bool]$results[$id].done) {
                $encodedServer = [uri]::EscapeDataString($SelectedServerId)
                $encodedId = [uri]::EscapeDataString([string]$id)
                $results[$id] = Invoke-PanelApi -Method GET -Path "/api/command/result?serverId=$encodedServer&id=$encodedId"
            }
        }
        if (@($ids | Where-Object { -not [bool]$results[$_].done }).Count -eq 0) { break }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)
    return [pscustomobject]@{ accepted = $Response; timedOut = @($ids | Where-Object { -not [bool]$results[$_].done }).Count -gt 0; results = @($ids | ForEach-Object { $results[$_] }) }
}

function Wait-LifecycleOperation {
    param([string]$SelectedServerId, [string]$Id, $Accepted)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $payload = $null
    do {
        $encodedServer = [uri]::EscapeDataString($SelectedServerId)
        $encodedId = [uri]::EscapeDataString($Id)
        $payload = Invoke-PanelApi -Method GET -Path "/api/server/operation?serverId=$encodedServer&id=$encodedId"
        if ($payload.operation -and [string]$payload.operation.status -in @("completed", "failed")) { break }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    return [pscustomobject]@{ accepted = $Accepted; timedOut = -not ($payload.operation -and [string]$payload.operation.status -in @("completed", "failed")); result = $payload }
}

try {
    $sessionState = Invoke-PanelApi -Method GET -Path "/api/auth/session"
    if ($sessionState.setupRequired) { throw "The panel requires first-time admin setup on 127.0.0.1." }
    if (-not $sessionState.authenticated) {
        if ([string]::IsNullOrWhiteSpace($Username)) { $Username = Read-Host "Panel username" }
        if (-not $Password) { $Password = Read-Host "Panel password" -AsSecureString }
        $credential = New-Object PSCredential($Username, $Password)
        $plainPassword = $credential.GetNetworkCredential().Password
        $login = Invoke-PanelApi -Method POST -Path "/api/auth/login" -Body @{ username = $Username; password = $plainPassword }
        $csrf = [string]$login.csrf
    }
    else { $csrf = [string]$sessionState.csrf }

    if ($Action -eq "system") { Invoke-PanelApi -Method GET -Path "/api/system" | ConvertTo-Json -Depth 12; exit 0 }
    if ($Action -eq "audit") { Invoke-PanelApi -Method GET -Path "/api/audit" | ConvertTo-Json -Depth 12; exit 0 }

    $status = Invoke-PanelApi -Method GET -Path "/api/status"
    if ($Action -eq "status") { $status | ConvertTo-Json -Depth 12; exit 0 }
    $server = Get-SelectedServer -Status $status
    $selectedId = [string]$server.id
    $encodedServerId = [uri]::EscapeDataString($selectedId)

    switch ($Action) {
        "players" {
            $output = Invoke-PanelApi -Method GET -Path "/api/players?serverId=$encodedServerId"
        }
        "operation" {
            if ([string]::IsNullOrWhiteSpace($OperationId)) { throw "operation requires -OperationId." }
            $encodedOperationId = [uri]::EscapeDataString($OperationId)
            $output = Invoke-PanelApi -Method GET -Path "/api/server/operation?serverId=$encodedServerId&id=$encodedOperationId"
        }
        "command" {
            Assert-WriteConfirmed
            if (-not $server.writable) { throw [string]$server.note }
            if ([string]::IsNullOrWhiteSpace($CommandBodyJson)) { throw "command requires -CommandBodyJson." }
            try { $body = $CommandBodyJson | ConvertFrom-Json } catch { throw "CommandBodyJson is invalid JSON." }
            if (-not $body.action) { throw "CommandBodyJson must contain action." }
            if ([string]$body.action -eq "worldgen" -and [string]$body.mode -in @("start", "recheck") -and [bool]$server.onlineKnown -and [int]$server.onlineCount -gt 0) {
                throw "World generation is blocked while $($server.onlineCount) players are online."
            }
            $body | Add-Member -NotePropertyName serverId -NotePropertyValue $selectedId -Force
            $accepted = Invoke-PanelApi -Method POST -Path "/api/command" -Body $body
            $output = Wait-CommandResults -Response $accepted -SelectedServerId $selectedId
        }
        "start" {
            Assert-WriteConfirmed
            if (-not $server.canStart) { throw [string]$server.startReason }
            $output = Invoke-PanelApi -Method POST -Path "/api/server/start" -Body @{ serverId = $selectedId }
        }
        { $_ -in @("stop", "restart") } {
            Assert-WriteConfirmed
            if ([bool]$server.onlineKnown -and [int]$server.onlineCount -gt 0 -and -not $AllowOnlinePlayers) {
                throw "$($server.onlineCount) players are online. Re-run only after explicit user authorization with -AllowOnlinePlayers."
            }
            if ($Action -eq "stop" -and -not $server.canStop) { throw [string]$server.note }
            if ($Action -eq "restart" -and -not $server.canRestart) { throw [string]$server.note }
            $confirm = if ($Action -eq "stop") { "SAVE_AND_STOP" } else { "SAVE_QUIT_RESTART" }
            $accepted = Invoke-PanelApi -Method POST -Path "/api/server/$Action" -Body @{ serverId = $selectedId; confirm = $confirm }
            $output = Wait-LifecycleOperation -SelectedServerId $selectedId -Id ([string]$accepted.operationId) -Accepted $accepted
        }
    }
    $output | ConvertTo-Json -Depth 12
}
finally {
    $plainPassword = $null
    $Password = $null
}
