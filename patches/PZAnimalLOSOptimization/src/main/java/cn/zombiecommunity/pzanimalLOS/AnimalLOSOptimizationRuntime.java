package cn.zombiecommunity.pzanimalLOS;

import java.util.AbstractSet;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Iterator;
import java.util.NoSuchElementException;
import java.util.Set;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.LongAdder;
import zombie.characters.IsoPlayer;
import zombie.characters.IsoZombie;
import zombie.characters.animals.IsoAnimal;
import zombie.iso.IsoCell;
import zombie.iso.IsoMovingObject;
import zombie.network.GameServer;

public final class AnimalLOSOptimizationRuntime {
    private static final AtomicBoolean STARTED = new AtomicBoolean();
    private static final LongAdder CALLS = new LongAdder();
    private static final LongAdder ORIGINAL_CANDIDATES = new LongAdder();
    private static final LongAdder REDUCED_CANDIDATES = new LongAdder();
    private static final LongAdder FAIL_OPEN = new LongAdder();
    private static final ThreadLocal<CandidateSet> SCRATCH =
            ThreadLocal.withInitial(CandidateSet::new);
    private static volatile boolean enabled;

    private AnimalLOSOptimizationRuntime() { }

    public static void start(boolean isEnabled, long reportSeconds) {
        enabled = isEnabled;
        if (!STARTED.compareAndSet(false, true)) return;
        long reportMillis = Math.multiplyExact(reportSeconds, 1000L);
        Thread reporter = new Thread(() -> reportLoop(reportMillis), "PZ-animal-los-report");
        reporter.setDaemon(true);
        reporter.setPriority(Thread.MIN_PRIORITY);
        reporter.start();
    }

    public static Set<IsoMovingObject> getCandidates(IsoCell cell, IsoAnimal animal) {
        Set<IsoMovingObject> original = cell.getObjectList();
        if (!enabled || animal == null || !GameServer.server) return original;
        try {
            ArrayList<IsoZombie> zombies = cell.getZombieList();
            ArrayList<IsoPlayer> players = GameServer.Players;
            CandidateSet candidates = SCRATCH.get();
            candidates.reset(zombies.size() + players.size() + 1);
            candidates.addIfActive(animal, original);
            for (int index = 0, size = zombies.size(); index < size; index++) {
                candidates.addIfActive(zombies.get(index), original);
            }
            for (int index = 0, size = players.size(); index < size; index++) {
                candidates.addIfActive(players.get(index), original);
            }
            CALLS.increment();
            ORIGINAL_CANDIDATES.add(original.size());
            REDUCED_CANDIDATES.add(candidates.size());
            return candidates;
        } catch (OutOfMemoryError exhausted) {
            SCRATCH.remove();
            FAIL_OPEN.increment();
            return original;
        } catch (RuntimeException | LinkageError failure) {
            FAIL_OPEN.increment();
            return original;
        }
    }

    private static void reportLoop(long reportMillis) {
        while (true) {
            try {
                Thread.sleep(reportMillis);
                long calls = CALLS.sumThenReset();
                long original = ORIGINAL_CANDIDATES.sumThenReset();
                long reduced = REDUCED_CANDIDATES.sumThenReset();
                long failOpen = FAIL_OPEN.sumThenReset();
                if (calls != 0L || failOpen != 0L) {
                    long filtered = Math.max(0L, original - reduced);
                    System.out.println("[PZAnimalLOS] summary calls=" + calls
                            + " originalCandidates=" + original
                            + " reducedCandidates=" + reduced
                            + " filteredCandidates=" + filtered
                            + " failOpen=" + failOpen);
                }
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                return;
            } catch (Throwable failure) {
                System.err.println("[PZAnimalLOS] report failed=" + failure);
                return;
            }
        }
    }

    static final class CandidateSet extends AbstractSet<IsoMovingObject> {
        private IsoMovingObject[] elements = new IsoMovingObject[64];
        private final HashSet<IsoMovingObject> seen = new HashSet<>(128);
        private int size;

        void reset(int expectedSize) {
            size = 0;
            seen.clear();
            if (expectedSize > elements.length) {
                elements = Arrays.copyOf(elements, Integer.highestOneBit(expectedSize - 1) << 1);
            }
        }

        void addIfActive(IsoMovingObject candidate, Set<IsoMovingObject> original) {
            if (candidate == null || !original.contains(candidate) || !seen.add(candidate)) return;
            elements[size++] = candidate;
        }

        @Override
        public Iterator<IsoMovingObject> iterator() {
            return new Iterator<>() {
                private int index;

                @Override
                public boolean hasNext() {
                    return index < size;
                }

                @Override
                public IsoMovingObject next() {
                    if (!hasNext()) throw new NoSuchElementException();
                    return elements[index++];
                }
            };
        }

        @Override
        public int size() {
            return size;
        }
    }
}
