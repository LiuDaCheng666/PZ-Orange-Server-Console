# Protocol Reference

## Files

```text
<cachedir>/Lua/PZAI-session-state.ini
<cachedir>/Lua/PZAI-session-1-events.log
...
<cachedir>/Lua/PZAI-session-5-events.log
```

The state file selects the active slot. Each log line is one UTF-8 JSON object
using schema `pzai.event/1`. Console copies are prefixed with `[PZAI_EVENT] `.

## Identity And Correlation

- `serverId`: configured logical server identifier.
- `sessionId`: one server-start session.
- `eventId`: session ID plus monotonic sequence.
- `timestampMs`: runtime timestamp.
- `actor.username`: server-authenticated player name for client packets.
- `requestId`: one-time diagnostic correlation token, valid for 30 seconds.
  In 0.6.1 and later it is present on the `agent.request`, server snapshot, and
  client snapshot. In 0.6.0 only the client snapshot carries it.
- `expectedServerSnapshot` and `expectedClientSnapshot`: the exact sides that
  a 0.6.1 diagnostic request expects. Use these fields when deciding whether a
  request is complete; client-only categories do not emit an empty server row.

## Limits

- Maximum encoded event: 12,288 bytes.
- Snapshot copy: depth 6, 512 nodes, 64 entries per table.
- Mod ID payload: 5,000 bytes; metadata: first 16 active IDs.
- Client error scan: latest 256 entries, latest eight unique messages.
- Request/chat text: configured bound, 512 bytes by default.
- Session logs: 1 to 10 slots, five by default.

## Built-In Categories

```text
action-state environment general interaction lua-errors mods network
performance player-state runtime-capabilities script-registry server-health simulation
vehicle-state weapon-model world-streaming
black-edge
```

`server-health` is server-only. `performance` and other dual-side categories
may produce both server and client snapshots. Missing B42 statistics use
`available=false` or an explicit reason; absence is not zero.

Every 0.6.1 server snapshot has `source=server`; an accepted client response
has `source=client`. Match exact `requestId`, authenticated actor, category,
and session. Do not pair unrelated snapshots solely because their timestamps
are close.

`black-edge` uses a separate 0.6.6 rolling-history protocol rather than a
single `diagnostic.snapshot`. Match `diagnostic.black-edge-started`, sample,
and summary events by exact `requestId` and actor. The client retains at most
45 one-second samples, sends no black-edge packets while idle, and uploads the
pre-request history only after the server receives the delayed chat request.
The visible green response therefore marks recovery. A frozen Lua main thread
cannot sample during the freeze; the next sample's `intervalMs` exposes that
gap.

## Local Summary Schema

The bundled `Get-PZAISessionSummary.ps1` emits `pzai.session-summary/1` with:

```text
instance       resolved cachedir, slot, session and active event path
window         valid/invalid lines, elapsed minutes, bytes and rates
eventCounts    count by structured event type
players        joined identities, latest online count and FPS summaries
health         heartbeat delay, log writes and pipeline failure counters
diagnostics    requestId correlation and source events
consoleRuntime counts after the latest SERVER STARTED marker
```

Console pattern counts are triage signals, not unique incident counts. One Java
exception can contain multiple matching stack lines. Use
`scripts/Get-PZConsoleIncidents.ps1` for primary-header incident totals,
normalized signatures, anonymous connection grouping, object evidence, and
bounded nearby compatibility traces.

## Capability Boundary

Current expected flags include:

```text
telemetry=true
rotatingSessionLogs=true
operationRequests=true
operationExecutorInterface=true
operationExecutorRegistered=false
operationExecutionEnabled=false
operationExecutor=false
agent=false
providerConfiguration=false
arbitraryCommands=false
```

`operationExecutor=false` means there is no effectively available executor; it
does not mean the registration interface is absent. This package includes no
executor, and execution plus all four operation groups default to false. A
separate server component can register one exact-operation executor, but core
requester, target, operation, master-switch, and group checks still apply.
Successful execution requires an `operation.executed` event with
`verified=true`.

There is no model provider, API-key store, Bridge, RCON path, Lua evaluation,
shell path, or arbitrary console command channel in this release.

## Optional Notice Channel

PZWebNotices 0.2.3 or later exposes a bounded UTF-8-safe `v3` local queue at:

```text
<cachedir>/Lua/PZWebNotices-queue.txt
```

Use the bundled `Send-PZWebNotice.ps1` instead of constructing records by hand.
The server writes `PZWebNotices-heartbeat.ini` and tab-delimited delivery rows
to `PZWebNotices-receipts.log`. `broadcast` or `directed` confirms server-side
dispatch; `client` confirms that a client processed the popup command. The
channel supports plain text, explicit newlines, bounded duration, three font
sizes, four styles, optional `#RRGGBB` colors, and player-directed delivery. It
does not support rich text, Lua, console commands, or operation authorization.

`server-health.providers.server.protocol.recentFailures` contains at most eight
bounded PZAI pipeline failures. `runtime-capabilities` reports selected B42
global/event availability without installing or replacing hooks.
