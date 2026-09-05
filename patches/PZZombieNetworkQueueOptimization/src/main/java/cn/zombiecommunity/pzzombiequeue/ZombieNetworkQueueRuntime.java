package cn.zombiecommunity.pzzombiequeue;

import java.util.IdentityHashMap;
import java.util.LinkedList;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;

public final class ZombieNetworkQueueRuntime {
    private static final Object PRESENT = new Object();
    private static final ThreadLocal<State> STATE = new ThreadLocal<>();
    private static final AtomicBoolean STARTED = new AtomicBoolean();
    private static final AtomicBoolean FAILURE_REPORTED = new AtomicBoolean();
    private static final AtomicLong LINEAR_QUERIES = new AtomicLong();
    private static final AtomicLong INDEX_BUILDS = new AtomicLong();
    private static final AtomicLong IDENTITY_HITS = new AtomicLong();
    private static final AtomicLong RESERVED_MISSES = new AtomicLong();
    private static final AtomicLong FAIL_OPEN = new AtomicLong();
    private static volatile boolean enabled;
    private static volatile boolean fused;
    private static volatile int threshold = 64;
    private static volatile int linearQueries = 3;

    private ZombieNetworkQueueRuntime() { }

    public static void start(boolean isEnabled, int configuredThreshold,
            int configuredLinearQueries, long reportSeconds) {
        enabled = isEnabled;
        threshold = configuredThreshold;
        linearQueries = configuredLinearQueries;
        if (!STARTED.compareAndSet(false, true)) return;
        long reportMillis = Math.multiplyExact(reportSeconds, 1_000L);
        Thread reporter = new Thread(() -> reportLoop(reportMillis), "PZ-zombie-queue-report");
        reporter.setDaemon(true);
        reporter.setPriority(Thread.MIN_PRIORITY);
        reporter.start();
    }

    public static void enter() {
        if (!enabled || fused) {
            clearStateQuietly();
            return;
        }
        try {
            State state = STATE.get();
            if (state == null) {
                state = new State();
                STATE.set(state);
            } else {
                state.clear();
            }
        } catch (RuntimeException | LinkageError | OutOfMemoryError failure) {
            tripFuse(failure);
        }
    }

    public static boolean containsAndReserve(LinkedList<?> list, Object candidate) {
        if (!enabled || fused) return list.contains(candidate);
        try {
            State state = STATE.get();
            if (state == null) {
                state = new State();
                STATE.set(state);
            }
            if (state.list != list) state.begin(list);

            int query = ++state.queries;
            int size = list.size();
            if (size < threshold || query <= linearQueries) {
                if (state.indexed) state.dropIndex();
                LINEAR_QUERIES.incrementAndGet();
                return list.contains(candidate);
            }

            if (!state.indexed || state.expectedSize != size) {
                state.buildIndex(list, size);
                INDEX_BUILDS.incrementAndGet();
            }
            if (state.index.containsKey(candidate)) {
                IDENTITY_HITS.incrementAndGet();
                return true;
            }
            state.index.put(candidate, PRESENT);
            state.expectedSize = Math.addExact(size, 1);
            RESERVED_MISSES.incrementAndGet();
            return false;
        } catch (RuntimeException | LinkageError | OutOfMemoryError failure) {
            tripFuse(failure);
            return list.contains(candidate);
        }
    }

    public static void exit() {
        try {
            State state = STATE.get();
            if (state != null) state.clear();
        } catch (RuntimeException | LinkageError | OutOfMemoryError failure) {
            tripFuse(failure);
        }
    }

    private static void tripFuse(Throwable failure) {
        fused = true;
        FAIL_OPEN.incrementAndGet();
        clearStateQuietly();
        if (FAILURE_REPORTED.compareAndSet(false, true)) {
            try {
                System.err.println("[PZZombieQueue] FUSED fail-open cause="
                        + failure.getClass().getName() + "; using vanilla LinkedList.contains");
            } catch (RuntimeException | LinkageError | OutOfMemoryError ignored) {
                // The optimization is already disabled; logging must not affect vanilla behavior.
            }
        }
    }

    private static void clearStateQuietly() {
        try {
            State state = STATE.get();
            if (state != null) state.clear();
            STATE.remove();
        } catch (RuntimeException | LinkageError | OutOfMemoryError ignored) {
            // Only recoverable optimization failures are suppressed.
        }
    }

    private static void reportLoop(long reportMillis) {
        while (true) {
            try {
                Thread.sleep(reportMillis);
                long linear = LINEAR_QUERIES.getAndSet(0L);
                long builds = INDEX_BUILDS.getAndSet(0L);
                long hits = IDENTITY_HITS.getAndSet(0L);
                long misses = RESERVED_MISSES.getAndSet(0L);
                long failOpen = FAIL_OPEN.getAndSet(0L);
                if (linear != 0L || builds != 0L || hits != 0L
                        || misses != 0L || failOpen != 0L) {
                    System.out.println("[PZZombieQueue] summary linearQueries=" + linear
                            + " indexBuilds=" + builds
                            + " identityHits=" + hits
                            + " reservedMisses=" + misses
                            + " failOpen=" + failOpen
                            + " fused=" + fused);
                }
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                return;
            } catch (RuntimeException | LinkageError | OutOfMemoryError failure) {
                try {
                    System.err.println("[PZZombieQueue] reporter stopped cause="
                            + failure.getClass().getName());
                } catch (RuntimeException | LinkageError | OutOfMemoryError ignored) {
                    // Reporter failure must not affect the game thread.
                }
                return;
            }
        }
    }

    static void configureForTests(boolean isEnabled, int configuredThreshold,
            int configuredLinearQueries) {
        clearStateQuietly();
        enabled = isEnabled;
        threshold = configuredThreshold;
        linearQueries = configuredLinearQueries;
        fused = false;
        FAILURE_REPORTED.set(false);
    }

    static boolean isFusedForTests() {
        return fused;
    }

    static boolean hasStateForTests() {
        return STATE.get() != null;
    }

    static Object currentListForTests() {
        State state = STATE.get();
        return state == null ? null : state.list;
    }

    static boolean hasIndexForTests() {
        State state = STATE.get();
        return state != null && state.indexed;
    }

    static int retainedIndexSizeForTests() {
        State state = STATE.get();
        return state == null || state.index == null ? 0 : state.index.size();
    }

    private static final class State {
        LinkedList<?> list;
        IdentityHashMap<Object, Object> index;
        boolean indexed;
        int queries;
        int expectedSize = -1;

        void begin(LinkedList<?> current) {
            clear();
            list = current;
        }

        void buildIndex(LinkedList<?> current, int size) {
            if (index == null) index = new IdentityHashMap<>(mapCapacity(size));
            else index.clear();
            for (Object item : current) index.put(item, PRESENT);
            indexed = true;
            expectedSize = size;
        }

        void dropIndex() {
            if (index != null) index.clear();
            indexed = false;
            expectedSize = -1;
        }

        void clear() {
            list = null;
            if (index != null) index.clear();
            indexed = false;
            queries = 0;
            expectedSize = -1;
        }

        private static int mapCapacity(int size) {
            if (size >= 750_000) return 1_000_000;
            return Math.max(16, size + (size >>> 1) + 1);
        }
    }
}
