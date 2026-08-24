# Evidence Workflow And Failure Traps

## Contents

- Instance resolution
- Startup and crash analysis
- Live lag and stall analysis
- Player and Mod attribution
- Network, CPU, memory, GC, and disk
- Patch evaluation
- Save and Mod safety
- Reporting standard

## Instance Resolution

Match all available fields: `zombie.network.GameServer`, exact `-servername`,
exact normalized `-cachedir`, Java executable, PID, process creation time, and
runtime root. Do not select “first java.exe” or infer that port order equals
server number. On this host the three servers can share one installation while
using different cache directories and heaps.

Prefer the live JVM command line for what is mounted now. Prefer managed profile
files for what will be mounted next restart. These can differ after a Web-panel
configuration change.

## Startup And Crash Analysis

1. Find the latest `*** SERVER STARTED ****` marker. Analyze from there for a
   running-session incident. For startup failure, include the lines before the
   expected marker and identify the final completed phase.
2. Distinguish a Java crash from an orderly stop, Web lifecycle stop, process
   termination, host shutdown, and failure before GameServer startup.
3. Check crash artifacts (`hs_err_pid`, configured `-XX:ErrorFile`, Windows
   Application log) only when process disappearance lacks an orderly shutdown.
4. An incomplete or abruptly truncated console file does not prove a JVM crash.
   Check managed lifecycle state and Windows events.
5. A startup warning count is not the number of broken Mods. Many warnings are
   repeated asset probes or one exception expanded into stack lines.

## Live Lag And Stall Analysis

Use a short log/process delta around a reported reproduction. Compare:

- new primary errors and warning families per minute;
- `Server is too busy` growth;
- process CPU expressed both as total-host percentage and approximate cores;
- working set/private bytes and console growth;
- player joins/leaves and chunk/object signatures;
- GC/safepoint evidence when available.

`Server is too busy` means the update loop missed its timing budget. It does not
identify the work. A prior measured case showed the dominant cost in
`ServerCell.RecalcAll2` / `IsoChunk.doLoadGridsquare`, while loader queues and GC
were healthy. Adding more loader workers would have fed the already-overloaded
main thread faster.

World-object mutation must remain on the game thread. Only immutable file I/O,
pure computation, and detached cache preparation are candidates for background
work. Do not promise generic “multi-threaded chunks” from Lua or a Java Agent.

## Player And Mod Attribution

Use SteamID as the primary identity key. Connection IDs are session-local;
usernames can change or collide; `null` is a placeholder. Correlate exact
timestamp/frame, SteamID, command, coordinates, target identity, and outcome.

A nearby player can trigger loading of an already-bad object without having
created it. A player request can be denied or fail before mutation. Report these
as “triggered loading/requested operation” unless authoritative evidence proves
the player changed world state.

For Mod attribution:

1. Resolve the server's active `Mods=` and `WorkshopItems=` values.
2. Map the exact Mod ID to its active Workshop branch and `mod.info`.
3. Search the logged class, Lua file, event name, item full type, Sprite, or
   network command in that source.
4. Confirm the relevant callback is actually registered in multiplayer/server
   mode. Dead single-player branches are not runtime evidence.
5. Prefer a narrow source fix. Avoid global monkey patches and broad packet
   drops unless protocol evidence proves they are safe.

## Network, CPU, Memory, GC, And Disk

- Task Manager bandwidth peaks do not reveal packet contents. Use ETW, pktmon,
  Wireshark, or server protocol instrumentation only for a bounded window, then
  remove it. Payload encryption may limit content visibility; rates and peers
  remain useful.
- A 200 Mbps adapter or plan is not evidence of saturation. Compare actual
  Mbps, queueing, packet loss, and game-thread timing.
- “All 32 CPUs briefly at 100%” can be GC, compression, backup, Workshop work,
  antivirus, or several servers. Capture per-process and GC evidence.
- High host RAM use is not automatically a leak. Separate JVM heap used,
  committed, soft max, native memory, OS cache, and three-server totals.
- With concurrent ZGC, a long concurrent cycle is not a stop-the-world pause.
  Safepoint duration and allocation stalls matter more.
- Log storms can cause disk pressure, but disk utilization alone does not show
  the writer. Attribute bytes by process/file before changing logging.

## Patch Evaluation

Use before/after windows with similar player count and activity. Record:

- exact game build and target-class hash;
- Agent JAR hash and version;
- current JVM command-line presence;
- `ACTIVE` or `REFUSED` marker;
- target signature rate before and after;
- new failure signatures and gameplay regressions.

Do not call a patch effective merely because the JAR exists or the JVM accepted
`-javaagent`. Do not call it harmful merely because players still experience a
different bottleneck. A patch can remove one log family without solving total
lag.

When an upstream/game update changes class bytes, a hash-gated Agent should
refuse injection and preserve vanilla behavior. Never “fix” that by adding a new
hash without reviewing the new bytecode and rerunning transform/integration
tests.

## Save And Mod Safety

- Java Agents in this deployment do not change save format, but a faulty world
  mutation can still damage runtime state. Respect each patch's documented
  target and rollback.
- Removing a content Mod can leave scripts, recipes, item types, vehicles,
  sprites, and world objects referenced by saves or player inventories. Startup
  warnings after removal are not guaranteed to disappear after one boot.
- Before deleting chunks or soft-resetting, stop cleanly and make a complete
  save/cache/database backup. Preserve safehouses and player surroundings only
  with an audited chunk-selection report.
- Never infer that “players did not build its objects” makes a building Mod safe
  to remove; loot, recipes, distributions, UI frameworks, and generated objects
  may still reference it.

## Reporting Standard

Use calibrated labels:

- **Confirmed**: direct source/protocol/stack/outcome evidence.
- **Strongly indicated**: multiple independent signals, no major contradiction.
- **Candidate**: temporal or frequency correlation requiring reproduction.
- **Unknown**: logs cannot distinguish causes.

Always include the analyzed startup marker or observation timestamps and make
clear whether counts are totals or rates.
