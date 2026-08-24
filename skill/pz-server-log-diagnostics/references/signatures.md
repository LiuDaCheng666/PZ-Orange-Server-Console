# Known Log Signatures

Use this catalog to classify evidence, not to bypass source verification.

## Performance And Streaming

### `Server is too busy`

Symptom: game update loop exceeded its budget. It can accompany chunk final
integration, Lua callbacks, packet floods, object exceptions, blocking I/O, GC,
or host contention. Count its rate and correlate the same frame/window. It is
not a root-cause signature.

### `Invalid SpriteConfig object!`

Meaning: an object retains an entity definition but its current Sprite is not
declared by that entity's SpriteConfig. Confirmed families include Open All
Containers `ct_oac_*` state sprites, B42 wooden-window dynamic states, and some
Lifestyle workbench states.

Impact: repeated chunk-load initialization and log I/O; SpriteConfig metadata
such as rotation/multi-tile relations can be unavailable. A safe fix maps only
confirmed state aliases and preserves vanilla initialization/failure cleanup.
Never skip all failed initialization: that older approach can leave incomplete
multi-tile buildings.

### `ObjectModDataPacket.parse: object is null`

Meaning depends on target type:

- 1: square IsoObject index;
- 2: player online ID;
- 3: zombie online ID;
- 4: animal online ID;
- 5: vehicle ID;
- 6: corpse/static moving-object index;
- 7: ordinary moving-object index.

For type 1, `objectId=-1` means the sender no longer had the object in
`square:getObjects()`. It is not proof of a permanently corrupt chunk. In the
measured OAC case, unconditional Sprite/ModData transmission after object
replacement produced periodic negative-index packets. `stale=0` means no
loaded-square out-of-range object was observed in that diagnostic window.

### `Packets limit has exceeded for State`

A connection sent a burst exceeding the packet-state limit. Treat separately
from SpriteConfig and ObjectModData. Correlate account, join/disconnect, network
conditions, and exact packet family before attributing cheating or a Mod.

## Object And Inventory Integrity

### `Entity is already registered`

Can abort Cell loading when the exact same GameEntity is registered twice.
Only suppress when object identity, `addedToEngine`, and non-removal state prove
an idempotent duplicate. ID collision or inconsistent state must stay visible.

### `ItemContainer.getCharacter` / `StackOverflowError`

Can result from a self-referential or cyclic `containingItem` owner chain.
Bounded identity-aware traversal is safer than hiding StackOverflow globally.

### `ItemContainer.AddItem: container already has id`

Indicates duplicate item identity in one container path. A nearby Mod stack or
login restoration batch is not sufficient attribution. Do not globally discard
AddItem calls without proving which duplicate is authoritative.

### `ItemPickInfo -> cannot get ID for container: inventorymale|inventoryfemale`

B42 ItemConfigurator omitted the two corpse-container names before building
integer selector buckets. The narrow fix registers those two IDs before bucket
construction. It does not change loot probabilities or item distributions.

## Actions And Interaction

### Long timed action finishes with no result

Two distinct causes must not be merged:

- A Lua callback returns no Boolean and `NetTimedAction.perform` throws.
- Server `ActionManager.stop(Action)` removes by one-byte action ID only;
  different players can legitimately share that ID, causing cross-player
  removal without Done/Reject.

Use client log plus server trace/outcome. The isolation Agent fixes the second
case only. Do not load its old trace Agent at the same time because both modify
`ActionManager.class`.

### Glass removal main-thread freeze

Original `removeGlassAttachments()` can revisit one attachment forever when
removal fails or callbacks mutate the list. Signature is one hot server thread,
window/glass interaction context, inability to save/quit, and repeated object
handling. The guard uses a bounded snapshot; it is not a general glass Mod
removal tool.

## Translation, UI, And Nonfatal Mod Errors

### `UnknownFormatConversionException: Conversion = ' '` or `')'`

B42 translation formatting treats `%` as a format introducer. Literal percent
must be `%%` in affected translation values. Patch the exact localization key
or Mod; do not globally rewrite all translated text at runtime.

### `writer_unavailable`

For PZ Web Notices, the notice file writer was unavailable. This affects Web
notice output, not automatically trading or game simulation. Check heartbeat,
queue/receipt protocol, permissions, and lifecycle.

### `AdvancedAnimator.visitFileFailed`

Often asset-probe noise for Mods without optional AnimSets/actiongroups paths.
Hundreds of lines do not mean hundreds of functional failures. Escalate only
when paired with a missing required animation or gameplay fault.

### Farming duplicate object / `getModData of null`

Client/server attempted to create or synchronize a farming object where one
already existed, then dereferenced a missing result. It can affect that plant's
sync. Coordinate and object lifecycle evidence are required before deleting a
chunk.

## Anti-Cheat Evidence

Separate a logged request, an Agent block, and a successful mutation.
Administrator-driven health edits can produce target-client health return
traffic; pair the target event with the prior authorized admin action before
scoring it. High-frequency normal commands from trading, Lifestyle,
PhunSprinters, music synchronization, and Web notice acknowledgements are not
cheating by count alone.

Use SteamID as identity. Preserve persistent OrangeAntiCheat event IDs and
deduplicate console/JSONL copies of the same event.
