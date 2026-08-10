---
name: pz-ai-server-telemetry
description: Inspect and diagnose a local Project Zomboid B42 Dedicated Server with PZAIServerAgent installed. Use to resolve the exact server instance, summarize rotating PZAI JSON logs, correlate player requests with server/client snapshots, measure telemetry overhead, read shared console logs safely, send authorized UTF-8 messages through a managed queue, locate active Workshop Mod source, and design evidence-based compatibility patches.
---

# PZ AI Server Telemetry

Operate only on the instance explicitly named by the user. Resolve the Java
executable, working directory, `-cachedir`, `-servername`, ports, active INI,
and process ID before reading or changing anything. Do not infer that another
Java process or a similarly named test server is the target.

## Establish The Instance

1. Inspect the selected managed profile and state when available. Otherwise,
   inspect candidate `java.exe` command lines and match all of executable path,
   `zombie.network.GameServer`, `-cachedir`, and `-servername`.
2. Read `<cachedir>/Lua/PZAI-session-state.ini`; use its `slot` to select the
   active event log. Never assume slot 1.
3. Read `mod.loaded` and `session.started` to verify the session, Mod version,
   game build, effective configuration, log store, and capability flags.

Run the bundled summary script on Windows PowerShell 5.1 or newer:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File \
  scripts/Get-PZAISessionSummary.ps1 \
  -CacheDir "D:\PZData" -ConsoleLog "D:\PZData\server-console.txt"
```

The script opens live files with read/write sharing, decodes strict UTF-8,
parses each JSONL row structurally, and reports event/byte rates, player FPS,
pipeline failures, diagnostic correlation, and console counts after the latest
`*** SERVER STARTED ****` marker.

Group current-session console failures by primary error header before assigning
importance or searching Mod source:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File \
  scripts/Get-PZConsoleIncidents.ps1 \
  -ConsoleLog "D:\PZData\server-console.txt"
```

This script avoids counting repeated exception and stack lines as separate
incidents. It anonymizes connection IDs, groups stable signatures, records
object coordinates when present, and attaches the nearest bounded
`[PZCompatTrace]` records before and after each example.

## Diagnose

1. Treat PZAI counters as telemetry-pipeline health, not as a complete count of
   JVM or other-Mod errors. Read the selected Dedicated Server console too.
2. Compare only the current startup window with a prior equivalent window.
   Whole-file totals mix sessions and cannot establish a regression.
3. Use `Get-PZConsoleIncidents.ps1` for unique incident totals. Treat nearby
   compatibility traces as temporal candidates only, never proof of ownership.
4. Prefer `preferredFps`; inspect `preferredFpsSource`. Keep
   `engineStatsFpsRaw` as supporting evidence only. Report sample count and
   range, and do not attribute client FPS changes to PZAI without a control.
5. Use `server-health` for uptime, real heartbeat delay, protocol failures,
   log-write failures, online count, Mod signature, and JVM-wide heap. Never
   present JVM-wide memory as memory used by one Mod. Do not invent TPS or a
   server Lua-error count when marked unavailable.
6. Inspect `protocol.recentFailures`, then locate the matching full console
   error. Zero pipeline failures do not prove that the server has no errors.

## Request Evidence

Ask a connected player to enter one relevant request at a time:

```text
ai 状态
ai 健康
ai 性能
ai 模组
ai 错误
ai 能力
ai 黑边
```

Use `action-state`, `vehicle-state`, `world-streaming`, `script-registry`,
`interaction`, `player-state`, or `weapon-model` only while reproducing that
domain. Heavy providers run on demand, not every frame.

For Mod 0.6.1 and later, correlate `agent.request` and all
`diagnostic.snapshot` events by exact `sessionId`, `requestId`, actor, and
category. Use `expectedServerSnapshot` and `expectedClientSnapshot` from the
request to determine completeness; a dual-side request requires one of each,
while a client-only category requires only `source=client`. In 0.6.0, the
server request and server snapshot lack `requestId`; timestamp adjacency is
legacy supporting evidence, not reliable machine correlation.

For black-edge or delayed map streaming, ask the affected player to enter
`ai黑边` as soon as practical. Do not expect an immediate response while the
client main thread or chat transport is blocked. In 0.6.6, the green response
means communication has resumed and the client is submitting up to 45 samples
recorded before the request reached the server. Correlate
`diagnostic.black-edge-started`, every `diagnostic.black-edge-sample`, and
`diagnostic.black-edge-summary` by exact session, actor, and `requestId`.
Prioritize `maxIntervalMs`, `minFps`, `maxUnavailableSquares`, missing samples,
and ordered network deltas. A long interval is evidence that the Lua Tick did
not run; unavailable Squares or packet changes are symptoms, not proof that a
specific Mod owns the stall.

## Interact Through A Managed Queue

Use `scripts/Send-PZManagedCommand.ps1` only when the selected server uses the
compatible UTF-8 JSON queue. Prefer `-BroadcastMessage` for non-ASCII text:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File \
  scripts/Send-PZManagedCommand.ps1 \
  -ProfilePath "C:\path\managed\production\profile.json" \
  -BroadcastMessage "请一名玩家输入：ai 性能"
```

By default the script permits only `players`, `help`, and `servermsg`. It
requires `-AllowStateChangingCommand` for anything else. Use that switch only
after the user explicitly authorizes the exact command and target. A receipt
with `stdin-flushed` proves delivery to standard input, not in-game effect.
Verify save, quit, moderation, and privilege outcomes from their authoritative
server evidence.

When the selected server has PZWebNotices loaded, prefer its directed popup
queue for a private player response or a styled multiline notice:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File \
  scripts/Send-PZWebNotice.ps1 \
  -CacheDir "D:\PZData" -TargetUsername "Alice" \
  -Title "AI reply" -Message "Please reproduce the issue once."
```

Omit `-TargetUsername` for a broadcast. The script writes only the bounded v3
data protocol under `<cachedir>/Lua`; it cannot run a console command or grant
permissions. A queued receipt means the server Mod accepted delivery, while a
`client` receipt means a client acknowledged showing it. Confirm
`PZWebNotices-heartbeat.ini` first and never infer delivery from the queue file
alone.

## Review Mods

Start from the runtime `mods` snapshot. Locate the exact active Mod ID, branch,
and Workshop item before reading source; obsolete downloaded branches are not
evidence that code loaded. Treat the Workshop tree as read-only. Search for
identifiers and APIs present in the logs, then record source paths, metadata,
and hashes before proposing a patch.

Prefer a small compatibility Mod loaded after the affected Mods. Do not edit a
Workshop subscription in place. Avoid persistent save keys unless essential.
State whether the patch can be added or removed after a clean stop and what an
upstream or game update invalidates. Validate offline, then on an isolated
server, then with a real client through connect, reproduce, save, disconnect,
restart, and reconnect.

Read `references/protocol.md` for event fields, limits, diagnostics, and
capability boundaries.

## Operation Boundary

Do not infer command authority from this Skill. Before submitting a PZAI typed
operation, verify all of these:

1. The user explicitly requested that exact operation and target.
2. `operationExecutorRegistered=true` and `operationExecutionEnabled=true`.
3. The executor supports the exact operation and its risk group is enabled.
4. Requester, target, and operation allowlists permit it.

Never work around a PZAI rejection through raw console text, RCON, shell, Lua
evaluation, or another operation name. Report success only from an
`operation.executed` event with `verified=true`, not from request acceptance,
`operation.approved`, or a managed-queue receipt.
