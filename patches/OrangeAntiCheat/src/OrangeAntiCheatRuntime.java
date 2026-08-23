package cn.zombiecommunity.orangeanticheat;

import java.lang.reflect.Method;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentLinkedQueue;
import zombie.characters.Capability;
import zombie.characters.IsoPlayer;

public final class OrangeAntiCheatRuntime {
    private static final String VERSION = "2.1.0";
    private static final String EVENT = "OnClientCommand";
    private static final String OWN_PLAYER_ONLY = "OwnPlayerOnly";
    private static final String HEALTH_REQUEST = "player.onHealthCheat";
    private static final String HEALTH_RELAY = "player.onHealthCheatCurrentPlayer";
    private static final long HEALTH_RELAY_TTL_NANOS = 15_000_000_000L;
    private static final int MAX_HEALTH_RELAY_TICKETS_PER_KEY = 8;
    private static final ConcurrentHashMap<String, ConcurrentLinkedQueue<Long>> HEALTH_RELAY_TICKETS =
            new ConcurrentHashMap<>();
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
    }

    private static String healthRelayKey(Long targetId, Long bodyPartIndex, String action) {
        if (targetId == null || bodyPartIndex == null || action == null
                || action.isBlank() || action.length() > 64) {
            return null;
        }
        return targetId + "|" + bodyPartIndex + "|" + action;
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
        System.out.println("[OrangeAntiCheat] event=blocked_client_command severity=critical"
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

    private static String stringValue(Object value) {
        return value == null ? "" : String.valueOf(value);
    }

    private static String token(String value) {
        if (value == null || value.isBlank()) {
            return "unknown";
        }
        return value.replaceAll("\\s+", "_").replaceAll("[=\\r\\n]", "_");
    }
}
