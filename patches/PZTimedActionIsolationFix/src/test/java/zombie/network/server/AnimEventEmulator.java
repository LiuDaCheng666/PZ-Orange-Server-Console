package zombie.network.server;

import zombie.core.NetTimedAction;

public final class AnimEventEmulator {
    private static final AnimEventEmulator INSTANCE = new AnimEventEmulator();
    public NetTimedAction removed;

    private AnimEventEmulator() {
    }

    public static AnimEventEmulator getInstance() {
        return INSTANCE;
    }

    public void remove(NetTimedAction action) {
        removed = action;
    }

    public void reset() {
        removed = null;
    }
}
