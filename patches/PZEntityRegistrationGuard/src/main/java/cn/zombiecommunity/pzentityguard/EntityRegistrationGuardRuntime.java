package cn.zombiecommunity.pzentityguard;

import java.util.concurrent.atomic.AtomicLong;

public final class EntityRegistrationGuardRuntime {
    private static final AtomicLong SUPPRESSED = new AtomicLong();

    private EntityRegistrationGuardRuntime() {
    }

    public static void reportSuppressedDuplicate(Object entity) {
        long count = SUPPRESSED.incrementAndGet();
        if (count <= 5 || (count & (count - 1)) == 0) {
            System.err.println("[PZEntityRegistrationGuard] suppressed idempotent duplicate registration"
                    + " count=" + count
                    + " class=" + (entity == null ? "null" : entity.getClass().getName())
                    + " identity=" + Integer.toHexString(System.identityHashCode(entity)));
        }
    }

    public static long suppressedCount() {
        return SUPPRESSED.get();
    }
}
