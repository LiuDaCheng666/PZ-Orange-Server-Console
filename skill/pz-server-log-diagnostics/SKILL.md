---
name: pz-server-log-diagnostics
description: Diagnose local Project Zomboid B42 dedicated-server startup failures, stalls, lag, disconnects, Mod exceptions, player-correlated incidents, and Java Agent status from live Windows processes and logs. Use when determining what actually happened on one server, whether a patch is active or harmful, or what evidence is still missing. Read-only by default; do not use it to restart servers, edit INI files, remove Mods, ban players, or alter saves.
---

# PZ Server Log Diagnostics

Diagnose one explicitly selected server from evidence. Do not treat a similarly
named server, another `java.exe`, an old startup window, or a copied desktop log
as the target without saying so.

## Start Here

On Windows, run the bundled inventory first:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File \
  "$HOME/.claude/skills/pz-server-log-diagnostics/scripts/Get-PZServerInventory.ps1"
```

Resolve the requested instance by exact `serverName` and verify PID,
`-cachedir`, executable, runtime root, console path, and command-line Agents.
Then collect one current-startup report:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File \
  "$HOME/.claude/skills/pz-server-log-diagnostics/scripts/Invoke-PZServerDiagnosis.ps1" \
  -ServerName server2
```

For an issue happening now, sample only new activity instead of repeatedly
rescanning the full log:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File \
  "$HOME/.claude/skills/pz-server-log-diagnostics/scripts/Watch-PZServerHealth.ps1" \
  -ServerName server2 -DurationSeconds 60 -IntervalSeconds 5
```

All scripts open live logs with read/write sharing and emit JSON. They do not
write game files, send commands, attach an Agent, or restart a process.

If the selected server has PZAIServerAgent telemetry, add its independent
session summary only after resolving that server's cache directory:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File \
  "$HOME/.claude/skills/pz-server-log-diagnostics/scripts/Get-PZAISessionSummary.ps1" \
  -CacheDir "D:\example-cache" -ConsoleLog "D:\example-cache\server-console.txt"
```

PZAI counters describe the telemetry pipeline and requested snapshots; they are
not a complete count of JVM or other-Mod errors. Keep them separate from the
Dedicated Server console aggregation.

## Evidence Rules

1. Restrict console analysis to the latest `*** SERVER STARTED ****` window.
   If the marker is absent, label results as whole-file and lower confidence.
2. Count primary error headers or normalized signatures, not every exception
   and stack line. A single exception can occupy many lines.
3. Separate observation from attribution. Temporal adjacency, coordinates, a
   player connection, high frequency, or a Mod name in a later stack frame is
   a lead, not proof of ownership.
4. Distinguish three Java Agent states:
   - present on disk;
   - present in the current JVM command line;
   - target transform verified by `ACTIVE` in an authoritative startup log.
   Missing `ACTIVE` from `server-console.txt` can be inconclusive because some
   Agents print before PZ initializes that log. `REFUSED unsupported` is
   conclusive that the target class stayed vanilla.
5. Compare rates over equivalent windows. Whole-file totals cannot show that a
   new Mod or patch caused a regression.
6. `Server is too busy`, CPU %, memory %, ping, and bandwidth peaks are
   symptoms. Never present one of them alone as the root cause.
7. Report uncertainty and the smallest next observation that can distinguish
   competing causes. Do not deploy a broad interception patch from ambiguous
   evidence.

Read [references/evidence-workflow.md](references/evidence-workflow.md) before
deep performance, crash, player-attribution, or Mod-source investigations.
Read [references/signatures.md](references/signatures.md) when classifying known
log families. Read [references/java-agents.md](references/java-agents.md) when
checking current patches, compatibility, conflicts, activation, or rollback.

## Source Attribution

Resolve the exact active Mod ID and Workshop item from the selected server's
current configuration before inspecting source. Check the active B42 branch,
not every downloaded copy. Treat Workshop files as read-only. Search identifiers
from the exception, command, Sprite, item full type, or stack frame. Record the
source path and relevant metadata before concluding that a Mod owns the fault.

When player attribution is requested, require a stable SteamID mapping from
connection/admin/command evidence. Ignore placeholder names such as `null`,
`unknown`, or `none`. A username match without SteamID is fallback evidence and
must not merge two accounts with the same name. Do not equate a request with a
successful state change; look for the authoritative game-side result.

## Safety Boundary

This Skill grants no mutation authority. Stay read-only unless the user later
authorizes one exact operation and target. In particular:

- Do not restart or kill Java, attach profilers/Agents, edit startup arguments,
  change INI/Sandbox settings, remove Mods, delete chunks, restore saves, or ban
  a player while merely diagnosing.
- Do not delete a JAR while its `-javaagent` argument remains configured.
- Do not remove a content Mod from a live save based only on startup warnings.
- Do not use old SpriteConfig behavior that skips failed initialization; it can
  leave inconsistent multi-tile state.
- Do not move PZ world-object reads or writes to arbitrary background threads.
  PZ world state and Lua are not generally thread-safe.
- Do not expose IP addresses, credentials, tokens, or raw connection IDs in a
  report unless the user explicitly needs that exact private evidence.

## Answer Shape

Lead with the current finding and confidence. Then state:

- selected instance and analyzed time/startup scope;
- highest-impact signatures with event counts or rates;
- evidence that supports and contradicts each attribution;
- Java Agent state as configured, JVM-mounted, ACTIVE, or REFUSED;
- whether this is log noise, a functional fault, or a plausible stall source;
- the next safe action, and whether it requires restart or player reproduction.

If evidence is insufficient, say exactly what cannot yet be known. Do not fill
the gap with a familiar Mod name.
