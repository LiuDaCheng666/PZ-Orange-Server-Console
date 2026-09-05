package cn.zombiecommunity.pzzombiequeue;

import java.util.LinkedList;

@SuppressWarnings({"removal", "serial"})
public final class RuntimeSemanticTest {
    private RuntimeSemanticTest() { }

    public static void main(String[] args) {
        testAdaptiveThresholdAndIdentityReservation();
        testListSwitchAndCleanup();
        testDisabledUsesVanillaEquality();
        testRecoverableFailuresFuseOpen();
        testVanillaFallbackExceptionPropagates();
        testFatalErrorsPropagate();
        System.out.println("RuntimeSemanticTest PASS");
    }

    private static void testAdaptiveThresholdAndIdentityReservation() {
        ZombieNetworkQueueRuntime.configureForTests(true, 64, 3);
        LinkedList<Object> small = populated(16);
        EqualValue existing = new EqualValue(7);
        EqualValue equalButDistinct = new EqualValue(7);
        small.add(existing);
        assertTrue(ZombieNetworkQueueRuntime.containsAndReserve(small, equalButDistinct),
                "small list must retain vanilla equals semantics");
        assertTrue(!ZombieNetworkQueueRuntime.hasIndexForTests(),
                "small list must remain linear");
        ZombieNetworkQueueRuntime.exit();

        LinkedList<Object> large = populated(64);
        ZombieNetworkQueueRuntime.enter();
        for (int index = 0; index < 3; index++) {
            assertTrue(ZombieNetworkQueueRuntime.containsAndReserve(large, large.get(index)),
                    "first three lookups must be linear hits");
            assertTrue(!ZombieNetworkQueueRuntime.hasIndexForTests(),
                    "index must not exist during first three lookups");
        }
        EqualValue equalExisting = new EqualValue(99);
        large.add(equalExisting);
        EqualValue identityMiss = new EqualValue(99);
        assertTrue(!ZombieNetworkQueueRuntime.containsAndReserve(large, identityMiss),
                "fourth large-list lookup must use identity semantics");
        assertTrue(ZombieNetworkQueueRuntime.hasIndexForTests(),
                "fourth large-list lookup must build the index");
        large.add(identityMiss);
        assertTrue(ZombieNetworkQueueRuntime.containsAndReserve(large, identityMiss),
                "reserved identity must become a hit after vanilla add");
        ZombieNetworkQueueRuntime.exit();
    }

    private static void testListSwitchAndCleanup() {
        ZombieNetworkQueueRuntime.configureForTests(true, 64, 3);
        LinkedList<Object> first = populated(64);
        LinkedList<Object> second = populated(64);
        ZombieNetworkQueueRuntime.enter();
        primeAndBuild(first);
        assertSame(first, ZombieNetworkQueueRuntime.currentListForTests(),
                "first list must be current");
        assertTrue(ZombieNetworkQueueRuntime.containsAndReserve(second, second.getFirst()),
                "new connection/list starts with a linear query");
        assertSame(second, ZombieNetworkQueueRuntime.currentListForTests(),
                "switching lists must release the previous list");
        assertTrue(!ZombieNetworkQueueRuntime.hasIndexForTests(),
                "new list must not inherit the old identity index");
        ZombieNetworkQueueRuntime.exit();
        assertTrue(ZombieNetworkQueueRuntime.hasStateForTests(),
                "normal exit must retain reusable scratch state");
        assertSame(null, ZombieNetworkQueueRuntime.currentListForTests(),
                "normal exit must release the current list");
        assertTrue(!ZombieNetworkQueueRuntime.hasIndexForTests(),
                "normal exit must mark the identity index inactive");
        assertTrue(ZombieNetworkQueueRuntime.retainedIndexSizeForTests() == 0,
                "normal exit must release all indexed objects");
    }

    private static void testDisabledUsesVanillaEquality() {
        ZombieNetworkQueueRuntime.configureForTests(false, 64, 3);
        LinkedList<Object> list = populated(64);
        list.add(new EqualValue(42));
        assertTrue(ZombieNetworkQueueRuntime.containsAndReserve(list, new EqualValue(42)),
                "disabled mode must call vanilla contains");
        assertTrue(!ZombieNetworkQueueRuntime.hasStateForTests(),
                "disabled mode must not retain state");
    }

    private static void testRecoverableFailuresFuseOpen() {
        assertRecoverableFailure(new RuntimeException("test"));
        assertRecoverableFailure(new LinkageError("test"));
        assertRecoverableFailure(new OutOfMemoryError("test"));
    }

    private static void assertRecoverableFailure(Error failure) {
        ZombieNetworkQueueRuntime.configureForTests(true, 64, 3);
        FaultySizeList list = new FaultySizeList(failure);
        list.add(new Object());
        Object candidate = list.getFirst();
        assertTrue(ZombieNetworkQueueRuntime.containsAndReserve(list, candidate),
                "recoverable Error must fall back to vanilla contains");
        assertTrue(ZombieNetworkQueueRuntime.isFusedForTests(),
                "recoverable Error must trip the fuse");
        assertTrue(!ZombieNetworkQueueRuntime.hasStateForTests(),
                "fuse must clear retained state");
    }

    private static void assertRecoverableFailure(RuntimeException failure) {
        ZombieNetworkQueueRuntime.configureForTests(true, 64, 3);
        FaultySizeList list = new FaultySizeList(failure);
        list.add(new Object());
        Object candidate = list.getFirst();
        assertTrue(ZombieNetworkQueueRuntime.containsAndReserve(list, candidate),
                "RuntimeException must fall back to vanilla contains");
        assertTrue(ZombieNetworkQueueRuntime.isFusedForTests(),
                "RuntimeException must trip the fuse");
        assertTrue(!ZombieNetworkQueueRuntime.hasStateForTests(),
                "fuse must clear retained state");
    }

    private static void testFatalErrorsPropagate() {
        assertFatalPropagates(new ThreadDeath());
        assertFatalPropagates(new StackOverflowError("test"));
        assertFatalPropagates(new InternalError("test"));
    }

    private static void testVanillaFallbackExceptionPropagates() {
        ZombieNetworkQueueRuntime.configureForTests(true, 64, 3);
        RuntimeException expected = new IllegalStateException("vanilla contains failure");
        LinkedList<Object> list = new FaultyFallbackList(expected);
        try {
            ZombieNetworkQueueRuntime.containsAndReserve(list, new Object());
            throw new AssertionError("vanilla fallback exception was swallowed");
        } catch (RuntimeException actual) {
            if (actual != expected) throw actual;
        }
        assertTrue(ZombieNetworkQueueRuntime.isFusedForTests(),
                "optimization failure must still trip the fuse");
    }

    private static void assertFatalPropagates(Error expected) {
        ZombieNetworkQueueRuntime.configureForTests(true, 64, 3);
        FaultySizeList list = new FaultySizeList(expected);
        try {
            ZombieNetworkQueueRuntime.containsAndReserve(list, new Object());
            throw new AssertionError(expected.getClass().getSimpleName() + " was swallowed");
        } catch (Error actual) {
            if (actual != expected) throw actual;
        } finally {
            ZombieNetworkQueueRuntime.exit();
        }
        assertTrue(!ZombieNetworkQueueRuntime.isFusedForTests(),
                "fatal Error must not be converted into optimization fuse state");
    }

    private static void primeAndBuild(LinkedList<Object> list) {
        for (int index = 0; index < 4; index++) {
            ZombieNetworkQueueRuntime.containsAndReserve(list, list.get(index));
        }
    }

    private static LinkedList<Object> populated(int size) {
        LinkedList<Object> result = new LinkedList<>();
        for (int index = 0; index < size; index++) result.add(new Object());
        return result;
    }

    private static void assertTrue(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    private static void assertSame(Object expected, Object actual, String message) {
        if (expected != actual) throw new AssertionError(message);
    }

    private static final class EqualValue {
        private final int value;

        EqualValue(int value) {
            this.value = value;
        }

        @Override
        public boolean equals(Object other) {
            return other instanceof EqualValue valueObject && valueObject.value == value;
        }

        @Override
        public int hashCode() {
            return value;
        }
    }

    private static final class FaultySizeList extends LinkedList<Object> {
        private final Throwable failure;

        FaultySizeList(Throwable failure) {
            this.failure = failure;
        }

        @Override
        public int size() {
            if (failure instanceof RuntimeException runtime) throw runtime;
            throw (Error) failure;
        }
    }

    private static final class FaultyFallbackList extends LinkedList<Object> {
        private final RuntimeException containsFailure;

        FaultyFallbackList(RuntimeException containsFailure) {
            this.containsFailure = containsFailure;
        }

        @Override
        public int size() {
            throw new RuntimeException("optimization failure");
        }

        @Override
        public boolean contains(Object candidate) {
            throw containsFailure;
        }
    }
}
