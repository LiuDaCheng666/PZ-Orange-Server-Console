package cn.zombiecommunity.pzactionisolation;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.Collection;
import java.util.List;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.LongAdder;

public final class TimedActionIsolationRuntime {
    private static final ConcurrentHashMap<Class<?>, Method> STOP_METHODS = new ConcurrentHashMap<>();
    private static final LongAdder EXACT_STOPS = new LongAdder();
    private static final LongAdder COLLISIONS_PREVENTED = new LongAdder();
    private static final LongAdder STALE_CANCELS = new LongAdder();
    private static final LongAdder FAILURES = new LongAdder();
    private static volatile Field gameServerField;
    private static volatile Field actionQueueField;
    private static volatile Field actionIdField;
    private static volatile Field actionPlayerIdField;
    private static volatile Class<?> netTimedActionClass;
    private static volatile Method emulatorGetInstance;
    private static volatile Method emulatorRemove;

    private TimedActionIsolationRuntime() {
    }

    public static boolean stopOwnedOnServer(Object action) {
        if (action == null || !isGameServer()) {
            return false;
        }

        int removed = 0;
        try {
            Collection<?> queue = actionQueue();
            prepareEmulatorMethods();

            int id = actionId(action);
            int owner = actionOwner(action);
            List<Object> ownedMatches = new ArrayList<>();
            int crossPlayerMatches = 0;
            for (Object candidate : queue) {
                if (candidate == null || actionId(candidate) != id) {
                    continue;
                }
                if (actionOwner(candidate) == owner) {
                    ownedMatches.add(candidate);
                } else {
                    crossPlayerMatches++;
                }
            }

            for (Object target : ownedMatches) {
                if (!queue.remove(target)) {
                    continue;
                }
                removed++;
                Method stopMethod = stopMethod(target.getClass());
                stopMethod.invoke(target);
                removeAnimationEmulation(target);
            }

            if (removed > 0) {
                EXACT_STOPS.add(removed);
            } else {
                STALE_CANCELS.increment();
                reportStaleCancel(id, owner, crossPlayerMatches);
            }

            if (crossPlayerMatches > 0) {
                COLLISIONS_PREVENTED.add(crossPlayerMatches);
                reportCollision(id, owner, crossPlayerMatches);
            }
            return true;
        } catch (Throwable failure) {
            reportFailure(failure, removed > 0);
            // Once an owned action has been removed, never enter vanilla's global ID removal path.
            return removed > 0;
        }
    }

    private static boolean isGameServer() {
        try {
            Field field = gameServerField;
            if (field == null) {
                field = Class.forName("zombie.network.GameServer").getField("server");
                gameServerField = field;
            }
            return field.getBoolean(null);
        } catch (Throwable failure) {
            reportFailure(failure, false);
            return false;
        }
    }

    private static Collection<?> actionQueue() throws ReflectiveOperationException {
        Field field = actionQueueField;
        if (field == null) {
            field = Class.forName("zombie.core.ActionManager").getDeclaredField("actions");
            field.setAccessible(true);
            actionQueueField = field;
        }
        Object value = field.get(null);
        if (!(value instanceof Collection<?> collection)) {
            throw new IllegalStateException("ActionManager.actions is not a Collection");
        }
        return collection;
    }

    private static Method stopMethod(Class<?> type) {
        return STOP_METHODS.computeIfAbsent(type, TimedActionIsolationRuntime::findStopMethod);
    }

    private static Method findStopMethod(Class<?> initialType) {
        Class<?> type = initialType;
        while (type != null) {
            try {
                Method method = type.getDeclaredMethod("stop");
                method.setAccessible(true);
                return method;
            } catch (NoSuchMethodException missing) {
                type = type.getSuperclass();
            }
        }
        throw new IllegalStateException("Action.stop() method not found for " + initialType.getName());
    }

    private static void prepareEmulatorMethods() throws ReflectiveOperationException {
        if (netTimedActionClass != null) {
            return;
        }
        synchronized (TimedActionIsolationRuntime.class) {
            if (netTimedActionClass != null) {
                return;
            }
            Class<?> actionType = Class.forName("zombie.core.NetTimedAction");
            Class<?> emulatorType = Class.forName("zombie.network.server.AnimEventEmulator");
            Method getInstance = emulatorType.getMethod("getInstance");
            Method remove = emulatorType.getMethod("remove", actionType);
            netTimedActionClass = actionType;
            emulatorGetInstance = getInstance;
            emulatorRemove = remove;
        }
    }

    private static void removeAnimationEmulation(Object action) throws ReflectiveOperationException {
        if (!netTimedActionClass.isInstance(action)) {
            return;
        }
        Object emulator = emulatorGetInstance.invoke(null);
        emulatorRemove.invoke(emulator, action);
    }

    private static int actionId(Object action) throws ReflectiveOperationException {
        Field field = actionIdField;
        if (field == null) {
            field = findField(action.getClass(), "id");
            actionIdField = field;
        }
        return ((Number) field.get(action)).intValue();
    }

    private static int actionOwner(Object action) throws ReflectiveOperationException {
        Field field = actionPlayerIdField;
        if (field == null) {
            field = findField(action.getClass(), "playerId");
            actionPlayerIdField = field;
        }
        Object playerId = field.get(action);
        if (playerId == null) {
            return Integer.MIN_VALUE;
        }
        Object value = playerId.getClass().getMethod("getID").invoke(playerId);
        return value instanceof Number ? ((Number) value).intValue() : Integer.MIN_VALUE;
    }

    private static Field findField(Class<?> initialType, String name) throws NoSuchFieldException {
        Class<?> type = initialType;
        while (type != null) {
            try {
                Field field = type.getDeclaredField(name);
                field.setAccessible(true);
                return field;
            } catch (NoSuchFieldException missing) {
                type = type.getSuperclass();
            }
        }
        throw new NoSuchFieldException(initialType.getName() + "." + name);
    }

    private static void reportCollision(int id, int owner, int matches) {
        long total = COLLISIONS_PREVENTED.sum();
        if (total <= 20 || (total & (total - 1)) == 0) {
            System.out.println("[PZTimedActionIsolationFix] prevented cross-player removal"
                    + " actionId=" + id
                    + " ownerOnlineId=" + owner
                    + " protectedActions=" + matches
                    + " totalProtected=" + total
                    + " exactStops=" + EXACT_STOPS.sum());
        }
    }

    private static void reportStaleCancel(int id, int owner, int crossPlayerMatches) {
        long total = STALE_CANCELS.sum();
        if (total <= 3 || (total & (total - 1)) == 0) {
            System.out.println("[PZTimedActionIsolationFix] ignored stale cancel"
                    + " actionId=" + id
                    + " ownerOnlineId=" + owner
                    + " crossPlayerMatches=" + crossPlayerMatches
                    + " totalStale=" + total);
        }
    }

    private static void reportFailure(Throwable failure, boolean afterRemoval) {
        FAILURES.increment();
        long count = FAILURES.sum();
        if (count <= 3 || (count & (count - 1)) == 0) {
            Throwable cause = failure.getCause() == null ? failure : failure.getCause();
            System.err.println("[PZTimedActionIsolationFix] runtime failure count=" + count
                    + " afterExactRemoval=" + afterRemoval
                    + " failure=" + cause.getClass().getName() + ":" + cause.getMessage());
        }
    }

    static void resetForTest() {
        STOP_METHODS.clear();
        EXACT_STOPS.reset();
        COLLISIONS_PREVENTED.reset();
        STALE_CANCELS.reset();
        FAILURES.reset();
        gameServerField = null;
        actionQueueField = null;
        actionIdField = null;
        actionPlayerIdField = null;
        netTimedActionClass = null;
        emulatorGetInstance = null;
        emulatorRemove = null;
    }

    static long[] countersForTest() {
        return new long[] {
                EXACT_STOPS.sum(), COLLISIONS_PREVENTED.sum(), STALE_CANCELS.sum(), FAILURES.sum()
        };
    }
}
