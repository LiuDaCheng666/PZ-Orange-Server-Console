# PZ Multiplayer Timed-Action Isolation Fix

## Purpose

Project Zomboid 42.20 `ActionManager.stop(Action)` delegates to
`remove(byte actionId, boolean)`. On a dedicated server, the removal predicate compares only the
one-byte action ID and not the owning player. Since clients generate action IDs independently, two
players can have active actions with the same ID. Stopping one action may remove the other player's
action without sending that player Done or Reject.

This Java agent changes only the dedicated-server `stop(Action)` path:

- read the owner ID and one-byte action ID from the cancellation request;
- remove only queued actions matching both fields and run their original `Action.stop()` cleanup;
- remove every same-owner match after an ID wrap, matching the client cancellation semantics;
- ignore stale cancellation requests without touching another player's same-ID action;
- remove each matching `NetTimedAction` from `AnimEventEmulator`;
- leave client behavior and normal Done, Reject and timeout cleanup unchanged;
- rate-limit diagnostics when a cross-player ID collision is prevented.

It does not force actions to complete and does not modify recipes, items, packets or save data.

## Compatibility guard

The transformer accepts only the reviewed 42.20 `ActionManager.class` SHA-256:

```text
9b9a993ed9ac7c1b1753ddaf350e7a24a7a69d8f4367b07a6a3b70f919213809
```

For any other class hash, the transformer returns the original class unchanged and logs `REFUSED`.
The hash must not be updated without reviewing the new bytecode.

## Validation

The included tests verify:

- the expected 42.20 target method shape and transform hook;
- hash refusal for altered class bytes;
- a distinct `GeneralActionPacket` request object cancelling queued actions by owner and ID;
- two players with action ID 126, where only the requesting player's actions are stopped;
- stale cancellation isolation and animation-emulator cleanup;
- successful JVM verification and loading of the transformed real game class.

The fix was subsequently confirmed effective on the affected dedicated server. Source is provided as
supplementary evidence for the upstream bug report, not as a request to run the attached agent.

## Public-source package

The public package intentionally excludes game binaries, decompiled game classes, ASM binaries,
compiled JARs, server configuration, server logs and player identifiers.
