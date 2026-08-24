package cn.zombiecommunity.pzactionisolation;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.Collection;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.LongAdder;

public final class TimedActionIsolationRuntime {
    private static final ConcurrentHashMap<Class<?>, Method> STOP_METHODS = new ConcurrentHashMap<>();
    private static final LongAdder EXACT_STOPS = new LongAdder();
    private static final LongAdder COLLISIONS_PREVENTED = new LongAdder();
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

    public static boolean stopExactOnServer(Object action) {
        if (action == null || !isGameServer()) {
            return false;
        }

        boolean removed = false;
        try {
            Collection<?> queue = actionQueue();
            Method stopMethod = stopMethod(action.getClass());
            prepareEmulatorMethods();

            int id = actionId(action);
            int owner = actionOwner(action);
            int crossPlayerMatches = countCrossPlayerMatches(queue, action, id, owner);

            if (!containsIdentity(queue, action)) {
                return true;
            }
            removed = queue.remove(action);
            if (!removed) {
                return true;
            }

            stopMethod.invoke(action);
            removeAnimationEmulation(action);
            EXACT_STOPS.increment();

            if (crossPlayerMatches > 0) {
                COLLISIONS_PREVENTED.add(crossPlayerMatches);
                reportCollision(id, owner, crossPlayerMatches);
            }
            return true;
        } catch (Throwable failure) {
            reportFailure(failure, removed);
            // Once the exact action has been removed, never enter vanilla's global ID removal path.
            return removed;
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

    private static int countCrossPlayerMatches(
            Collection<?> queue, Object target, int id, int owner) throws ReflectiveOperationException {
        int matches = 0;
        for (Object candidate : queue) {
            if (candidate != null
                    && candidate != target
                    && actionId(candidate) == id
                    && actionOwner(candidate) != owner) {
                matches++;
            }
        }
        return matches;
    }

    private static boolean containsIdentity(Collection<?> queue, Object target) {
        for (Object candidate : queue) {
            if (candidate == target) {
                return true;
            }
        }
        return false;
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
        return new long[] {EXACT_STOPS.sum(), COLLISIONS_PREVENTED.sum(), FAILURES.sum()};
    }
}
