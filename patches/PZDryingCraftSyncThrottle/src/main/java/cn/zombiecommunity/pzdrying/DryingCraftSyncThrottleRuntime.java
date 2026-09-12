package cn.zombiecommunity.pzdrying;

import java.util.Collections;
import java.util.Map;
import java.util.WeakHashMap;
import java.util.concurrent.atomic.LongAdder;

public final class DryingCraftSyncThrottleRuntime {
    private static final String DRYING_CLASS =
            "zombie.entity.components.crafting.DryingCraftLogic";
    private static final Map<Object, Long> LAST_SEND =
            Collections.synchronizedMap(new WeakHashMap<>());
    private static final LongAdder ALLOWED = new LongAdder();
    private static final LongAdder THROTTLED = new LongAdder();
    private static volatile long intervalNanos;

    private DryingCraftSyncThrottleRuntime() { }

    public static void start(long intervalMs, long reportSeconds) {
        intervalNanos = intervalMs * 1_000_000L;
        Thread reporter = new Thread(() -> reportLoop(reportSeconds), "PZ-drying-sync-throttle-report");
        reporter.setDaemon(true);
        reporter.setPriority(Thread.MIN_PRIORITY);
        reporter.start();
    }

    public static boolean allow(boolean originalDecision, Object craftLogic) {
        if (!originalDecision || craftLogic == null
                || !DRYING_CLASS.equals(craftLogic.getClass().getName())) {
            return originalDecision;
        }
        long now = System.nanoTime();
        synchronized (LAST_SEND) {
            Long previous = LAST_SEND.get(craftLogic);
            if (previous == null || now - previous >= intervalNanos) {
                LAST_SEND.put(craftLogic, now);
                ALLOWED.increment();
                return true;
            }
        }
        THROTTLED.increment();
        return false;
    }

    private static void reportLoop(long reportSeconds) {
        while (true) {
            try {
                Thread.sleep(reportSeconds * 1000L);
                long allowed = ALLOWED.sumThenReset();
                long throttled = THROTTLED.sumThenReset();
                if (allowed != 0 || throttled != 0) {
                    System.out.println("[PZDryingSyncThrottle] summary allowed=" + allowed
                            + " throttled=" + throttled + " tracked=" + LAST_SEND.size());
                }
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                return;
            }
        }
    }
}
