---
name: operate-pz-control-panel
description: Operate and troubleshoot Project Zomboid dedicated servers through the authenticated PZ Web Control Panel. Use for checking server/process/JVM/player/item status, inspecting logs or audit data, running supported server commands, starting or safely stopping/restarting managed servers, and diagnosing panel command or lifecycle results.
---

# Operate PZ Control Panel

Use the panel API instead of writing queue files or terminating Java directly. Run `scripts/Invoke-PZPanel.ps1` for repeatable authenticated operations and read `references/api.md` when constructing command bodies or interpreting results.

## Workflow

1. Locate the panel URL. Prefer `PZ_PANEL_URL`; otherwise use `http://127.0.0.1:8790` on the server computer.
2. Query `status` first and resolve the exact server ID. Never select a server only by Java process order or port assumption.
3. Inspect `alive`, `writable`, `canStart`, `canStop`, `canRestart`, `onlineKnown`, `onlineCount`, and `note` before writing.
4. Use the helper script. Prompt for credentials; never save passwords in the Skill, source tree, command history, audit details, or output.
5. For commands, report the final command result, not only queue acceptance. A delivered receipt proves the controller received a command; it does not always prove the game-side effect succeeded.
6. For stop/restart, use only the panel lifecycle endpoint. Wait for completion and report each final operation stage. Never kill `java.exe` directly.
7. Re-query status and audit after impactful operations.

## Safety Rules

- Treat status, players, system, audit, and operation lookup as read-only.
- Require explicit user intent and `-ConfirmAction` for command, start, stop, and restart.
- Refuse stop/restart with known online players unless the user explicitly authorizes disruption and `-AllowOnlinePlayers` is supplied.
- Refuse world generation `start` or `recheck` while players are online.
- Never restart unrelated Java processes. Match the selected panel server ID.
- Never edit `users.json` remotely. User/profile management is intentionally local-only.
- For forgotten `admin` passwords, use the deployment's local reset BAT only after remote-desktop access to that server. Do not implement a Web authentication bypass.
- Preserve current server configuration and logs unless the user explicitly requests a change.

## Common Calls

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  "$env:USERPROFILE\.codex\skills\operate-pz-control-panel\scripts\Invoke-PZPanel.ps1" -Action status

powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  "$env:USERPROFILE\.codex\skills\operate-pz-control-panel\scripts\Invoke-PZPanel.ps1" `
  -Action players -ServerId servertest

powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  "$env:USERPROFILE\.codex\skills\operate-pz-control-panel\scripts\Invoke-PZPanel.ps1" `
  -Action command -ServerId servertest -CommandBodyJson '{"action":"save"}' -ConfirmAction

powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  "$env:USERPROFILE\.codex\skills\operate-pz-control-panel\scripts\Invoke-PZPanel.ps1" `
  -Action restart -ServerId servertest -ConfirmAction
```

Do not place a password literal in examples or command arguments. Let the script prompt for a secure string.

## Local Source Inspection

When the API is unavailable, locate `PZ-ControlPanel.ps1`, then inspect `panel-state.json`, `servers.json`, managed state, and logs read-only. Do not assume the panel directory is the same on every deployment. Prefer `PZ_PANEL_ROOT`; otherwise search narrowly in the user-specified deployment directory.

Read `references/api.md` for endpoints, confirmation tokens, command payload examples, result meanings, and local-only restrictions.
