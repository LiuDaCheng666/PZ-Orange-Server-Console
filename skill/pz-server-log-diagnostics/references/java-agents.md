# Current Java Agents

This catalog describes the eight Agents shipped with the panel repository.
Always compare it with the selected JVM command line and current source/JAR
hashes; deployment can change.

| Agent | Narrow purpose | Positive evidence | Important boundary/conflict |
| --- | --- | --- | --- |
| `OrangeAntiCheat-agent.jar` | Audit or reject selected unauthorized client command, item-transform, and health-sync paths | `agent_installed`, matching `guard_ready`, persisted event JSONL | A request count is not a successful mutation; admin-authorized health actions must be paired |
| `PZServerStreamingStability-agent.jar` | Consume invalid ObjectModData safely and briefly queue valid-index packets whose square is not loaded | `ACTIVE` target classes and diagnostics banner | Does not cache chunks, prefetch the map, or make world writes multithreaded |
| `PZGlassRemovalGuard-agent.jar` | Bound `removeGlassAttachments()` cleanup to prevent an infinite loop | `ACTIVE: IsoGridSquare.removeGlassAttachments is guarded` | Only the glass-attachment cleanup method; unsupported hash stays vanilla |
| `PZItemContainerCycleGuard-agent.jar` | Stop cyclic container-owner traversal from causing StackOverflow | `ACTIVE ItemContainer.getCharacter` | Returns no owner only for an invalid/cyclic chain; does not repair or delete items |
| `PZEntityRegistrationGuard-agent.jar` | Suppress proven idempotent registration of the same already-added entity | `ACTIVE EngineEntityManager.addEntityInternal` | Does not suppress ID collisions, inconsistent state, or removal-state errors |
| `PZItemPickInfoContainerFix-agent.jar` | Register `inventorymale` and `inventoryfemale` before ItemConfig buckets build | `ACTIVE ItemConfigurator.Preprocess hook` plus `registered inventorymale=...` | Does not alter loot distributions or fix unrelated ItemPickInfo IDs |
| `PZTimedActionIsolationFix-agent.jar` | Stop the exact player's Action instead of all players sharing one byte ID | `ACTIVE exact per-player timed-action stop` | Cannot load with `PZTimedActionTrace`; does not fix Lua callbacks returning nil |
| `PZSpriteConfigAliasPatch-agent.jar` | Normalize 24 confirmed dynamic Sprite aliases during vanilla lookup/verification | three class `ACTIVE` lines plus `agent installed aliases=24` | Cannot load with old skip/cache `PZSpriteConfigGuard`; unknown Sprite mismatches remain visible |

## State Interpretation

- **JAR present**: install inventory only.
- **Configured in managed profile**: will be requested on next managed start.
- **Mounted in current JVM command line**: this process started with the Agent.
- **ACTIVE**: target transform accepted for the expected class bytes.
- **REFUSED unsupported**: Agent loaded, class hash/shape did not match, target
  behavior remained vanilla.
- **Guard/runtime event observed**: transformed path actually executed.

Do not label “mounted” as “verified ACTIVE”. Conversely, if the current JVM
command line contains an Agent but its early `ACTIVE` message was emitted before
PZ opened `server-console.txt`, absence from that file is not proof of failure.
Use managed wrapper output, retained process logs, or a target runtime event.

## Rollback

All listed Agents are server-side and do not intentionally change save format.
Rollback still requires a complete server stop, removal of the exact
`-javaagent` argument, and a normal restart. Never delete or rename a mounted
JAR while leaving the next-start argument intact. Preserve the old JAR and
profile backup until the server completes startup and a save/reconnect check.

## Build Update Rule

The repository versions contain source, ASM dependency/license, build scripts,
tests, deployed JARs, and checksums. After a game update:

1. compare target class bytes;
2. review changed methods and invariants;
3. update transforms deliberately;
4. run transform, integration, and real game-class load tests;
5. test on an isolated server;
6. then deploy and verify `ACTIVE`.

Never update only an accepted SHA-256 value.
