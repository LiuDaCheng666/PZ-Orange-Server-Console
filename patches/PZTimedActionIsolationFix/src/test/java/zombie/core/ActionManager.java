package zombie.core;

import java.util.concurrent.ConcurrentLinkedQueue;

public final class ActionManager {
    private static final ConcurrentLinkedQueue<Action> actions = new ConcurrentLinkedQueue<>();

    private ActionManager() {
    }

    public static void add(Action action) {
        actions.add(action);
    }

    public static boolean contains(Action action) {
        return actions.contains(action);
    }

    public static void clear() {
        actions.clear();
    }
}
