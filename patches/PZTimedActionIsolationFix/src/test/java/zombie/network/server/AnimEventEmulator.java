package zombie.network.server;

import java.util.ArrayList;
import java.util.List;
import zombie.core.NetTimedAction;

public final class AnimEventEmulator {
    private static final AnimEventEmulator INSTANCE = new AnimEventEmulator();
    public final List<NetTimedAction> removed = new ArrayList<>();

    private AnimEventEmulator() {
    }

    public static AnimEventEmulator getInstance() {
        return INSTANCE;
    }

    public void remove(NetTimedAction action) {
        removed.add(action);
    }

    public void reset() {
        removed.clear();
    }
}
