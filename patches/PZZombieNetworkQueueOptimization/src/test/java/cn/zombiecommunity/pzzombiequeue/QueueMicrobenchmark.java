package cn.zombiecommunity.pzzombiequeue;

import java.util.LinkedList;
import java.util.Locale;

public final class QueueMicrobenchmark {
    private static final int[] SIZES = {0, 16, 64, 300, 1_000, 5_000};
    private static final int QUERIES = 300;
    private static volatile int blackhole;

    private QueueMicrobenchmark() { }

    public static void main(String[] args) {
        System.out.println("QueueMicrobenchmark (ns/query, lower is better)");
        System.out.println("size\tvanilla\toptimized\tratio");
        for (int size : SIZES) {
            int rounds = size >= 5_000 ? 20 : size >= 1_000 ? 40 : 100;
            runVanilla(size, 5);
            runOptimized(size, 5);
            long vanilla = runVanilla(size, rounds);
            long optimized = runOptimized(size, rounds);
            double vanillaPerQuery = (double) vanilla / (rounds * QUERIES);
            double optimizedPerQuery = (double) optimized / (rounds * QUERIES);
            System.out.printf(Locale.ROOT, "%d\t%.1f\t%.1f\t%.2fx%n",
                    size, vanillaPerQuery, optimizedPerQuery,
                    vanillaPerQuery / optimizedPerQuery);
        }
        if (blackhole == Integer.MIN_VALUE) System.out.println("unreachable");
    }

    private static long runVanilla(int initialSize, int rounds) {
        Object[] candidates = candidates();
        long start = System.nanoTime();
        for (int round = 0; round < rounds; round++) {
            LinkedList<Object> list = populated(initialSize);
            for (Object candidate : candidates) {
                if (!list.contains(candidate)) list.add(candidate);
            }
            blackhole ^= list.size();
        }
        return System.nanoTime() - start;
    }

    private static long runOptimized(int initialSize, int rounds) {
        Object[] candidates = candidates();
        ZombieNetworkQueueRuntime.configureForTests(true, 64, 3);
        long start = System.nanoTime();
        for (int round = 0; round < rounds; round++) {
            LinkedList<Object> list = populated(initialSize);
            ZombieNetworkQueueRuntime.enter();
            try {
                for (Object candidate : candidates) {
                    if (!ZombieNetworkQueueRuntime.containsAndReserve(list, candidate)) {
                        list.add(candidate);
                    }
                }
            } finally {
                ZombieNetworkQueueRuntime.exit();
            }
            blackhole ^= list.size();
        }
        return System.nanoTime() - start;
    }

    private static LinkedList<Object> populated(int size) {
        LinkedList<Object> result = new LinkedList<>();
        for (int index = 0; index < size; index++) result.add(new Object());
        return result;
    }

    private static Object[] candidates() {
        Object[] result = new Object[QUERIES];
        for (int index = 0; index < result.length; index++) result[index] = new Object();
        return result;
    }
}

