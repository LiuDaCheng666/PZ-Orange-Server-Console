package cn.zombiecommunity.pzanimalLOS;

import java.util.AbstractSet;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
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
    private static volatile boolean enabled;

    private AnimalLOSOptimizationRuntime() { }

    public static void start(boolean isEnabled, long reportSeconds) {
        enabled = isEnabled;
        if (!STARTED.compareAndSet(false, true)) return;
        Thread reporter = new Thread(() -> reportLoop(reportSeconds), "PZ-animal-los-report");
        reporter.setDaemon(true);
        reporter.setPriority(Thread.MIN_PRIORITY);
        reporter.start();
    }

    public static Set<IsoMovingObject> getCandidates(IsoCell cell, IsoAnimal animal) {
        if (!enabled || cell == null || animal == null) {
            return cell == null ? Set.of() : cell.getObjectList();
        }
        try {
            ArrayList<IsoZombie> zombies = cell.getZombieList();
            ArrayList<IsoPlayer> players = GameServer.Players;
            int reduced = 1 + zombies.size() + players.size();
            CALLS.increment();
            ORIGINAL_CANDIDATES.add(cell.getObjectList().size());
            REDUCED_CANDIDATES.add(reduced);
            return new CandidateSet(animal, zombies, players);
        } catch (Throwable failure) {
            FAIL_OPEN.increment();
            return cell.getObjectList();
        }
    }

    private static void reportLoop(long reportSeconds) {
        while (true) {
            try {
                Thread.sleep(reportSeconds * 1000L);
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
            }
        }
    }

    static final class CandidateSet extends AbstractSet<IsoMovingObject> {
        private final IsoAnimal animal;
        private final List<IsoZombie> zombies;
        private final List<IsoPlayer> players;

        CandidateSet(IsoAnimal animal, List<IsoZombie> zombies, List<IsoPlayer> players) {
            this.animal = animal;
            this.zombies = zombies;
            this.players = players;
        }

        @Override
        public Iterator<IsoMovingObject> iterator() {
            return new CandidateIterator(animal, zombies.iterator(), players.iterator());
        }

        @Override
        public int size() {
            return 1 + zombies.size() + players.size();
        }
    }

    private static final class CandidateIterator implements Iterator<IsoMovingObject> {
        private IsoAnimal animal;
        private final Iterator<IsoZombie> zombies;
        private final Iterator<IsoPlayer> players;

        CandidateIterator(IsoAnimal animal, Iterator<IsoZombie> zombies,
                Iterator<IsoPlayer> players) {
            this.animal = animal;
            this.zombies = zombies;
            this.players = players;
        }

        @Override
        public boolean hasNext() {
            return animal != null || zombies.hasNext() || players.hasNext();
        }

        @Override
        public IsoMovingObject next() {
            if (animal != null) {
                IsoAnimal result = animal;
                animal = null;
                return result;
            }
            if (zombies.hasNext()) return zombies.next();
            if (players.hasNext()) return players.next();
            throw new NoSuchElementException();
        }
    }
}
