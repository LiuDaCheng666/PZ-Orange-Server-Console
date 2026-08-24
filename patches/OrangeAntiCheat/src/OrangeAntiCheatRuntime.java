package cn.zombiecommunity.orangeanticheat;

import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.atomic.AtomicLong;
import zombie.ZomboidFileSystem;
import zombie.characters.Capability;
import zombie.characters.IsoPlayer;
import zombie.characters.BodyDamage.BodyDamage;
import zombie.characters.BodyDamage.BodyPart;
import zombie.inventory.InventoryItem;
import zombie.inventory.ItemContainer;
import zombie.network.GameServer;
import zombie.network.IConnection;
import zombie.network.fields.character.PlayerID;

public final class OrangeAntiCheatRuntime {
    private static final String VERSION = "2.5.0";
    private static final String EVENT = "OnClientCommand";
    private static final String OWN_PLAYER_ONLY = "OwnPlayerOnly";
    private static final String HEALTH_REQUEST = "player.onHealthCheat";
    private static final String HEALTH_RELAY = "player.onHealthCheatCurrentPlayer";
    private static final long HEALTH_RELAY_TTL_NANOS = 15_000_000_000L;
    private static final int MAX_HEALTH_RELAY_TICKETS_PER_KEY = 8;
    private static final ConcurrentHashMap<String, ConcurrentLinkedQueue<Long>> HEALTH_RELAY_TICKETS =
            new ConcurrentHashMap<>();
    private static final ConcurrentHashMap<Short, Long> HEALTH_SYNC_AUTHORIZATIONS =
            new ConcurrentHashMap<>();
    private static final ConcurrentHashMap<Long, Long> HEALTH_SYNC_LOG_TIMES =
            new ConcurrentHashMap<>();
    private static final ThreadLocal<HealthSnapshot> HEALTH_SNAPSHOT = new ThreadLocal<>();
    private static final float HEALTH_INCREASE_EPSILON = 1.0f;
    private static final long HEALTH_LOG_INTERVAL_NANOS = 5_000_000_000L;
    private static final long EVENT_LOG_MAX_BYTES = 8L * 1024L * 1024L;
    private static final int EVENT_LOG_ROTATIONS = 5;
    private static final Object EVENT_LOG_LOCK = new Object();
    private static final DateTimeFormatter EVENT_TIME_FORMAT =
            DateTimeFormatter.ofPattern("dd-MM-yy HH:mm:ss.SSS");
    private static final String EVENT_INSTANCE = Long.toUnsignedString(System.currentTimeMillis(), 36);
    private static final AtomicLong EVENT_SEQUENCE = new AtomicLong();
    private static volatile long lastEventLogErrorNanos;
    private static final Map<String, Capability> ADMIN_COMMANDS = Map.ofEntries(
            Map.entry("object.addFireOnSquare", Capability.UseDebugContextMenu),
            Map.entry("object.addSmokeOnSquare", Capability.UseDebugContextMenu),
            Map.entry("object.addExplosionOnSquare", Capability.UseDebugContextMenu),
            Map.entry("object.addFluidDebug", Capability.UseDebugContextMenu),
            Map.entry("object.clearContainerExplore", Capability.UseDebugContextMenu),
            Map.entry("object.addWaterContainer", Capability.UseDebugContextMenu),
            Map.entry("object.removeFluidContainer", Capability.UseDebugContextMenu),
            Map.entry("player.setWeight", Capability.UseHealthCheat),
            Map.entry("erosion.disableForSquare", Capability.UseDebugContextMenu),
            Map.entry("event.thunder", Capability.UseDebugContextMenu));
    private static final Map<String, Boolean> SELF_COMMANDS = Map.of(
            "player.onVehicleSleep", Boolean.TRUE,
            "player.onDropHeavyItem", Boolean.TRUE);

    private OrangeAntiCheatRuntime() {
    }

    public static boolean shouldBlock(
            Object eventValue,
            Object moduleValue,
            Object commandValue,
            Object playerValue,
            Object argsValue) {
        if (!EVENT.equals(eventValue)) {
            return false;
        }
        String module = stringValue(moduleValue);
        String command = stringValue(commandValue);
        String key = module + "." + command;
        Capability capability = ADMIN_COMMANDS.get(key);
        boolean selfOnly = SELF_COMMANDS.containsKey(key);
        boolean healthRequest = HEALTH_REQUEST.equals(key);
        boolean healthRelay = HEALTH_RELAY.equals(key);
        if (capability == null && !selfOnly && !healthRequest && !healthRelay) {
            return false;
        }

        IsoPlayer player = playerValue instanceof IsoPlayer ? (IsoPlayer) playerValue : null;
        try {
            if (player == null) {
                logBlocked(null, module, command, capabilityName(capability, selfOnly, healthRequest, healthRelay),
                        "missing_player", null);
                return true;
            }
            if (healthRequest) {
                if (player.getRole() == null || !player.getRole().hasCapability(Capability.UseHealthCheat)) {
                    logBlocked(player, module, command, Capability.UseHealthCheat.name(),
                            "missing_capability", readNumericField(argsValue, "id"));
                    return true;
                }
                Long targetId = readNumericField(argsValue, "id");
                Long bodyPartIndex = readNumericField(argsValue, "bodyPartIndex");
                String action = readTextField(argsValue, "action");
                if (targetId == null || bodyPartIndex == null || action == null) {
                    logBlocked(player, module, command, Capability.UseHealthCheat.name(),
                            "invalid_health_request", targetId);
                    return true;
                }
                rememberHealthRelay(targetId, bodyPartIndex, action);
                return false;
            }
            if (healthRelay) {
                boolean administrator = player.getRole() != null
                        && player.getRole().hasCapability(Capability.UseHealthCheat);
                if (administrator) {
                    return false;
                }
                Long targetId = readNumericField(argsValue, "id");
                Long bodyPartIndex = readNumericField(argsValue, "bodyPartIndex");
                String action = readTextField(argsValue, "action");
                if (targetId == null || targetId.longValue() != player.getOnlineID()) {
                    logBlocked(player, module, command, "AuthorizedHealthRelay",
                            targetId == null ? "missing_target" : "target_mismatch", targetId);
                    return true;
                }
                if (bodyPartIndex != null && action != null
                        && consumeHealthRelay(targetId, bodyPartIndex, action)) {
                    return false;
                }
                logBlocked(player, module, command, "AuthorizedHealthRelay",
                        "missing_or_expired_health_authorization", targetId);
                return true;
            }
            if (capability != null) {
                boolean allowed = player.getRole() != null && player.getRole().hasCapability(capability);
                if (allowed) {
                    return false;
                }
                logBlocked(player, module, command, capability.name(), "missing_capability", null);
                return true;
            }

            Long targetId = readNumericField(argsValue, "id");
            if (targetId != null && targetId.longValue() == player.getOnlineID()) {
                return false;
            }
            logBlocked(player, module, command, OWN_PLAYER_ONLY,
                    targetId == null ? "missing_target" : "target_mismatch", targetId);
            return true;
        } catch (Throwable failure) {
            logBlocked(player, module, command, capabilityName(capability, selfOnly, healthRequest, healthRelay),
                    "guard_error_" + token(failure.getClass().getSimpleName()), null);
            return true;
        }
    }

    public static boolean shouldRejectItemTransform(
            int itemId,
            Object sourceValue,
            Object destinationValue,
            String requestedType,
            Object playerValue) {
        if (requestedType == null || requestedType.isBlank()) {
            return false;
        }
        String route = sourceValue == destinationValue ? "same_container" : "cross_container";
        IsoPlayer player = playerValue instanceof IsoPlayer ? (IsoPlayer) playerValue : null;
        try {
            if (!(sourceValue instanceof ItemContainer source)) {
                logBlockedItemTransform(
                        player, null, requestedType, itemId, 0, route, "missing_source_container");
                return true;
            }
            if (player == null) {
                logBlockedItemTransform(
                        null, null, requestedType, itemId, 0, route, "missing_player");
                return true;
            }

            InventoryItem carrier = source.getItemWithID(itemId);
            if (carrier == null) {
                logBlockedItemTransform(
                        player, null, requestedType, itemId, 0, route, "carrier_not_in_source");
                return true;
            }

            boolean sourceOwned = source.isInCharacterInventory(player);
            List<String> allowedTargets = carrier.getClothingItemExtra();
            if (!shouldRejectItemTransformValues(
                    sourceOwned,
                    true,
                    allowedTargets,
                    carrier.getModule(),
                    carrier.getFullType(),
                    requestedType)) {
                return false;
            }

            logBlockedItemTransform(
                    player,
                    carrier,
                    requestedType,
                    itemId,
                    allowedTargets == null ? 0 : allowedTargets.size(),
                    route,
                    sourceOwned ? "target_not_in_clothing_extra_options" : "source_not_owned_by_player");
            return true;
        } catch (Throwable failure) {
            logBlockedItemTransform(
                    player,
                    null,
                    requestedType,
                    itemId,
                    0,
                    route,
                    "guard_error_" + token(failure.getClass().getSimpleName()));
            return true;
        }
    }

    public static boolean beforeHealthSync(Object packetValue, Object connectionValue) {
        HEALTH_SNAPSHOT.remove();
        if (!GameServer.server) {
            return false;
        }
        if (!(packetValue instanceof PlayerID packet)
                || !(connectionValue instanceof IConnection connection)) {
            return false;
        }

        IsoPlayer player = packet.getPlayer();
        if (player == null) {
            return false;
        }
        if (!connection.hasPlayer(player.getOnlineID())) {
            logObservedHealthSync(player, packetValue, 0, 0.0f, "target_not_owned_by_connection");
            return false;
        }
        if (connection.getRole() != null
                && connection.getRole().hasCapability(Capability.UseHealthCheat)) {
            return false;
        }
        if (hasHealthSyncAuthorization(player.getOnlineID())) {
            return false;
        }

        BodyDamage damage = player.getBodyDamage();
        if (damage == null) {
            return false;
        }
        ArrayList<BodyPart> parts = damage.getBodyParts();
        float[] health = new float[parts.size()];
        for (int index = 0; index < health.length; index++) {
            health[index] = parts.get(index).getHealth();
        }
        HEALTH_SNAPSHOT.set(new HealthSnapshot(player, health));
        return false;
    }

    public static void afterHealthSync(Object packetValue) {
        HealthSnapshot snapshot = HEALTH_SNAPSHOT.get();
        HEALTH_SNAPSHOT.remove();
        if (snapshot == null || !GameServer.server) {
            return;
        }
        try {
            BodyDamage damage = snapshot.player.getBodyDamage();
            if (damage == null) {
                return;
            }
            ArrayList<BodyPart> parts = damage.getBodyParts();
            int count = Math.min(parts.size(), snapshot.health.length);
            int increasedParts = 0;
            float maxIncrease = 0.0f;
            for (int index = 0; index < count; index++) {
                BodyPart part = parts.get(index);
                float before = snapshot.health[index];
                float after = part.getHealth();
                if (!isSuspiciousHealthIncrease(before, after)) {
                    continue;
                }
                increasedParts++;
                maxIncrease = Math.max(maxIncrease, Float.isFinite(after) ? after - before : Float.POSITIVE_INFINITY);
            }
            if (increasedParts > 0) {
                logObservedHealthSync(
                        snapshot.player,
                        packetValue,
                        increasedParts,
                        maxIncrease,
                        Float.isFinite(maxIncrease) ? "client_health_increase" : "non_finite_health");
            }
        } catch (Throwable failure) {
            logObservedHealthSync(
                    snapshot.player,
                    packetValue,
                    0,
                    0.0f,
                    "guard_error_" + token(failure.getClass().getSimpleName()));
        }
    }

    static boolean isSuspiciousHealthIncrease(float before, float after) {
        if (!Float.isFinite(after)) {
            return true;
        }
        return Float.isFinite(before) && after > before + HEALTH_INCREASE_EPSILON;
    }

    static boolean shouldRejectItemTransformValues(
            boolean sourceOwned,
            boolean carrierFound,
            List<String> allowedTargets,
            String sourceModule,
            String sourceFullType,
            String requestedType) {
        if (requestedType == null || requestedType.isBlank()) {
            return false;
        }
        if (!sourceOwned || !carrierFound) {
            return true;
        }
        return !isAllowedItemTransform(
                allowedTargets, sourceModule, sourceFullType, requestedType);
    }

    static boolean isAllowedItemTransform(
            List<String> allowedTargets,
            String sourceModule,
            String sourceFullType,
            String requestedType) {
        if (requestedType == null) {
            return false;
        }
        if (requestedType.equals(sourceFullType)) {
            return true;
        }
        if (allowedTargets == null) {
            return false;
        }
        for (String target : allowedTargets) {
            if (target == null || target.isBlank()) {
                continue;
            }
            String fullTarget = target.indexOf('.') >= 0
                    ? target : stringValue(sourceModule) + "." + target;
            if (requestedType.equals(fullTarget)) {
                return true;
            }
        }
        return false;
    }

    static String policyFor(String module, String command) {
        String key = stringValue(module) + "." + stringValue(command);
        Capability capability = ADMIN_COMMANDS.get(key);
        if (capability != null) {
            return capability.name();
        }
        if (HEALTH_REQUEST.equals(key)) {
            return Capability.UseHealthCheat.name();
        }
        if (HEALTH_RELAY.equals(key)) {
            return "AuthorizedHealthRelay";
        }
        return SELF_COMMANDS.containsKey(key) ? OWN_PLAYER_ONLY : "";
    }

    static Long readNumericField(Object table, String key) {
        if (table == null) {
            return null;
        }
        try {
            Method rawget = table.getClass().getMethod("rawget", Object.class);
            Object value = rawget.invoke(table, key);
            if (value instanceof Number) {
                return ((Number) value).longValue();
            }
            if (value != null) {
                return Long.valueOf(String.valueOf(value));
            }
        } catch (ReflectiveOperationException | NumberFormatException ignored) {
            return null;
        }
        return null;
    }

    static String readTextField(Object table, String key) {
        if (table == null) {
            return null;
        }
        try {
            Method rawget = table.getClass().getMethod("rawget", Object.class);
            Object value = rawget.invoke(table, key);
            if (value == null) {
                return null;
            }
            String text = String.valueOf(value);
            return text.isBlank() || text.length() > 64 ? null : text;
        } catch (ReflectiveOperationException ignored) {
            return null;
        }
    }

    static void rememberHealthRelay(Long targetId, Long bodyPartIndex, String action) {
        String key = healthRelayKey(targetId, bodyPartIndex, action);
        if (key == null) {
            return;
        }
        long now = System.nanoTime();
        ConcurrentLinkedQueue<Long> tickets = HEALTH_RELAY_TICKETS.computeIfAbsent(
                key, ignored -> new ConcurrentLinkedQueue<>());
        while (tickets.size() >= MAX_HEALTH_RELAY_TICKETS_PER_KEY) {
            tickets.poll();
        }
        tickets.offer(now + HEALTH_RELAY_TTL_NANOS);
        if (targetId >= Short.MIN_VALUE && targetId <= Short.MAX_VALUE) {
            HEALTH_SYNC_AUTHORIZATIONS.put(targetId.shortValue(), now + HEALTH_RELAY_TTL_NANOS);
        }
    }

    static boolean consumeHealthRelay(Long targetId, Long bodyPartIndex, String action) {
        String key = healthRelayKey(targetId, bodyPartIndex, action);
        if (key == null) {
            return false;
        }
        ConcurrentLinkedQueue<Long> tickets = HEALTH_RELAY_TICKETS.get(key);
        if (tickets == null) {
            return false;
        }
        long now = System.nanoTime();
        Long deadline;
        while ((deadline = tickets.poll()) != null) {
            if (deadline >= now) {
                if (tickets.isEmpty()) {
                    HEALTH_RELAY_TICKETS.remove(key, tickets);
                }
                return true;
            }
        }
        HEALTH_RELAY_TICKETS.remove(key, tickets);
        return false;
    }

    static void clearHealthRelayTicketsForTest() {
        HEALTH_RELAY_TICKETS.clear();
        HEALTH_SYNC_AUTHORIZATIONS.clear();
    }

    private static String healthRelayKey(Long targetId, Long bodyPartIndex, String action) {
        if (targetId == null || bodyPartIndex == null || action == null
                || action.isBlank() || action.length() > 64) {
            return null;
        }
        return targetId + "|" + bodyPartIndex + "|" + action;
    }

    private static boolean hasHealthSyncAuthorization(short onlineId) {
        Long deadline = HEALTH_SYNC_AUTHORIZATIONS.get(onlineId);
        if (deadline == null) {
            return false;
        }
        if (deadline >= System.nanoTime()) {
            return true;
        }
        HEALTH_SYNC_AUTHORIZATIONS.remove(onlineId, deadline);
        return false;
    }

    private static String capabilityName(
            Capability capability,
            boolean selfOnly,
            boolean healthRequest,
            boolean healthRelay) {
        if (capability != null) {
            return capability.name();
        }
        if (healthRequest) {
            return Capability.UseHealthCheat.name();
        }
        if (healthRelay) {
            return "AuthorizedHealthRelay";
        }
        return selfOnly ? OWN_PLAYER_ONLY : "ProtectedCommand";
    }

    private static void logBlocked(
            IsoPlayer player,
            String module,
            String command,
            String capability,
            String reason,
            Long targetId) {
        long steamId = player == null ? 0L : player.getSteamID();
        String username = player == null ? "unknown" : token(player.getUsername());
        short onlineId = player == null ? -1 : player.getOnlineID();
        int x = player == null ? 0 : player.getXi();
        int y = player == null ? 0 : player.getYi();
        int z = player == null ? 0 : player.getZi();
        emitEvent("[OrangeAntiCheat] event=blocked_client_command severity=critical"
                + " version=" + VERSION
                + " mode=javaagent"
                + " steamId=" + steamId
                + " username=" + username
                + " onlineId=" + onlineId
                + " module=" + token(module)
                + " command=" + token(command)
                + " capability=" + token(capability)
                + " reason=" + token(reason)
                + " targetId=" + (targetId == null ? "unknown" : targetId)
                + " x=" + x + " y=" + y + " z=" + z);
    }

    private static void logBlockedItemTransform(
            IsoPlayer player,
            InventoryItem carrier,
            String requestedType,
            int itemId,
            int allowedCount,
            String route,
            String reason) {
        emitEvent("[OrangeAntiCheat] event=blocked_item_transform severity=critical"
                + " version=" + VERSION
                + " mode=javaagent"
                + " steamId=" + (player == null ? 0L : player.getSteamID())
                + " username=" + (player == null ? "unknown" : token(player.getUsername()))
                + " onlineId=" + (player == null ? -1 : player.getOnlineID())
                + " sourceType=" + (carrier == null ? "unknown" : token(carrier.getFullType()))
                + " targetType=" + token(requestedType)
                + " itemId=" + itemId
                + " allowedCount=" + allowedCount
                + " route=" + token(route)
                + " reason=" + token(reason)
                + " x=" + (player == null ? 0 : player.getXi())
                + " y=" + (player == null ? 0 : player.getYi())
                + " z=" + (player == null ? 0 : player.getZi()));
    }

    private static void logObservedHealthSync(
            IsoPlayer player,
            Object packetValue,
            int increasedParts,
            float maxIncrease,
            String reason) {
        long steamId = player == null ? 0L : player.getSteamID();
        long now = System.nanoTime();
        Long previous = HEALTH_SYNC_LOG_TIMES.put(steamId, now);
        if (previous != null && now - previous < HEALTH_LOG_INTERVAL_NANOS) {
            return;
        }
        emitEvent("[OrangeAntiCheat] event=observed_health_sync severity=warning"
                + " version=" + VERSION
                + " mode=javaagent"
                + " steamId=" + steamId
                + " username=" + (player == null ? "unknown" : token(player.getUsername()))
                + " onlineId=" + (player == null ? -1 : player.getOnlineID())
                + " packet=" + token(packetValue == null ? "unknown" : packetValue.getClass().getSimpleName())
                + " increasedParts=" + increasedParts
                + " maxIncrease=" + (Float.isFinite(maxIncrease) ? maxIncrease : "non_finite")
                + " reason=" + token(reason)
                + " action=observed_not_blocked"
                + " x=" + (player == null ? 0 : player.getXi())
                + " y=" + (player == null ? 0 : player.getYi())
                + " z=" + (player == null ? 0 : player.getZi()));
    }

    private static void emitEvent(String message) {
        String eventMessage = message + " eventId=" + EVENT_INSTANCE + "-" + EVENT_SEQUENCE.incrementAndGet();
        System.out.println(eventMessage);
        try {
            persistEvent(eventMessage);
        } catch (Throwable failure) {
            long now = System.nanoTime();
            if (now - lastEventLogErrorNanos >= 60_000_000_000L) {
                lastEventLogErrorNanos = now;
                System.err.println("[OrangeAntiCheat] event=persistence_warning version=" + VERSION
                        + " reason=" + token(failure.getClass().getSimpleName()));
            }
        }
    }

    private static void persistEvent(String message) throws Exception {
        synchronized (EVENT_LOG_LOCK) {
            String cacheDir = ZomboidFileSystem.instance.getCacheDir();
            Path directory = Path.of(cacheDir, "Lua");
            Files.createDirectories(directory);
            Path current = directory.resolve("OrangeAntiCheat-events.jsonl");
            if (Files.exists(current) && Files.size(current) >= EVENT_LOG_MAX_BYTES) {
                rotateEventLogs(directory, current);
            }
            String time = LocalDateTime.now().format(EVENT_TIME_FORMAT);
            String record = "{\"time\":\"" + jsonEscape(time) + "\",\"message\":\""
                    + jsonEscape(message) + "\"}" + System.lineSeparator();
            Files.writeString(current, record, StandardCharsets.UTF_8,
                    StandardOpenOption.CREATE, StandardOpenOption.APPEND);
        }
    }

    private static void rotateEventLogs(Path directory, Path current) throws Exception {
        Files.deleteIfExists(directory.resolve("OrangeAntiCheat-events." + EVENT_LOG_ROTATIONS + ".jsonl"));
        for (int index = EVENT_LOG_ROTATIONS - 1; index >= 1; index--) {
            Path source = directory.resolve("OrangeAntiCheat-events." + index + ".jsonl");
            if (Files.exists(source)) {
                Files.move(source, directory.resolve("OrangeAntiCheat-events." + (index + 1) + ".jsonl"),
                        StandardCopyOption.REPLACE_EXISTING);
            }
        }
        Files.move(current, directory.resolve("OrangeAntiCheat-events.1.jsonl"),
                StandardCopyOption.REPLACE_EXISTING);
    }

    private static String jsonEscape(String value) {
        StringBuilder result = new StringBuilder(value.length() + 16);
        for (int index = 0; index < value.length(); index++) {
            char character = value.charAt(index);
            switch (character) {
                case '\\' -> result.append("\\\\");
                case '"' -> result.append("\\\"");
                case '\r' -> result.append("\\r");
                case '\n' -> result.append("\\n");
                case '\t' -> result.append("\\t");
                default -> {
                    if (character < 0x20) {
                        result.append(String.format("\\u%04x", (int) character));
                    } else {
                        result.append(character);
                    }
                }
            }
        }
        return result.toString();
    }

    private static final class HealthSnapshot {
        private final IsoPlayer player;
        private final float[] health;

        private HealthSnapshot(IsoPlayer player, float[] health) {
            this.player = player;
            this.health = health;
        }
    }

    private static String stringValue(Object value) {
        return value == null ? "" : String.valueOf(value);
    }

    private static String token(String value) {
        if (value == null || value.isBlank()) {
            return "unknown";
        }
        String normalized = value.replaceAll("\\s+", "_").replaceAll("[=\\r\\n]", "_");
        return normalized.length() <= 160 ? normalized : normalized.substring(0, 160);
    }
}
