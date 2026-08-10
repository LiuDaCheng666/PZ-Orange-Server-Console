# PZ Control Panel API Reference

## Authentication

- `GET /api/auth/session`: reports setup/auth state.
- `POST /api/auth/login`: JSON `{ "username": "...", "password": "..." }`.
- Keep the returned session cookie and send returned `csrf` as `X-PZ-CSRF` on every authenticated non-GET request.
- Never persist credentials. Login throttling applies after repeated failures.

## Read Endpoints

- `GET /api/status`: all configured server states and exact IDs.
- `GET /api/players?serverId=ID`: online-first player directory with SteamID data when available.
- `GET /api/system`: host CPU, memory, disk, network, and server process metrics.
- `GET /api/audit`: recent panel audit entries.
- `GET /api/command/result?serverId=ID&id=REQUEST_ID`: command receipt and parsed output.
- `GET /api/server/operation?serverId=ID&id=OPERATION_ID`: stop/restart progress.
- `GET /api/items/status?serverId=ID`: item index build/cache status.
- `GET /api/items/catalog?serverId=ID&q=TEXT&page=1&pageSize=60`: item catalog search.

Important status fields:

- `alive`: matching game Java process exists.
- `writable`: managed command controller is attached.
- `canStart`, `canStop`, `canRestart`: lifecycle capability for this exact state.
- `onlineKnown`: whether online count is trustworthy.
- `onlineCount`, `onlinePlayers`, `onlineSteamIds`: current players.
- `note`, `startReason`: operator-facing reason when an action is unavailable.

## Command Endpoint

`POST /api/command` accepts a supported structured action plus `serverId`. The helper adds `serverId` automatically.

Examples for `-CommandBodyJson`:

```json
{"action":"save"}
{"action":"players"}
{"action":"stats"}
{"action":"broadcast","message":"Maintenance in ten minutes"}
{"action":"check-mod-updates"}
{"action":"worldgen","mode":"status"}
```

Use the Web UI or inspect `Resolve-Command` in the deployed `PZ-ControlPanel.ps1` for less common structured payload fields. Do not send raw console text by bypassing the resolver.

Command result semantics:

- `queued`: request exists but the managed host has not acknowledged it.
- `delivered`: queue receipt exists; game output may still be pending.
- `response`: relevant server output settled.
- `failed`: controller or command processing failed.
- `done=true` with `noOutput=true`: command was delivered but no attributable output appeared before timeout. This can be normal for commands such as broadcasts; verify through state/log/audit when necessary.

For Mod update checks, rely on `resultCode` and `resultMessage`. A line such as `CheckModsNeedUpdate: Mods updated` means updates are needed/available according to the panel parser, not that Workshop files were automatically installed.

## Lifecycle Endpoints

- Start: `POST /api/server/start` with `{ "serverId": "ID" }`.
- Stop: `POST /api/server/stop` with `{ "serverId": "ID", "confirm": "SAVE_AND_STOP" }`.
- Restart: `POST /api/server/restart` with `{ "serverId": "ID", "confirm": "SAVE_QUIT_RESTART" }`.

Safe restart stages are save command, save receipt/result, quit command/result, process exit, then managed start. Poll the operation endpoint until `completed` or `failed`. Never substitute `Stop-Process`, Task Manager termination, or a direct Java kill.

## Local-Only Operations

`/api/users*` and profile management are restricted to requests originating on the server computer. Use `http://127.0.0.1:8790` through a local/remote-desktop session. The reserved `admin` account cannot be renamed, disabled, or deleted in portable builds.
