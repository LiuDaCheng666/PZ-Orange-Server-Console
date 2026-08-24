package cn.zombiecommunity.pzcontainerguard;

import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.LongAdder;

public final class ItemContainerCycleGuardRuntime {
    private static final long REPORT_INTERVAL_NANOS = 30_000_000_000L;
    private static final AtomicLong NEXT_REPORT_NANOS = new AtomicLong();
    private static final LongAdder BLOCKED = new LongAdder();

    private ItemContainerCycleGuardRuntime() {
    }

    public static void report(String reason, int depth) {
        BLOCKED.increment();
        long now = System.nanoTime();
        long next = NEXT_REPORT_NANOS.get();
        if (now < next || !NEXT_REPORT_NANOS.compareAndSet(next, now + REPORT_INTERVAL_NANOS)) {
            return;
        }
        System.err.println("[PZItemContainerCycleGuard] BLOCKED invalid container owner chain"
                + " reason=" + reason + " depth=" + depth + " total=" + BLOCKED.sum());
    }
}
