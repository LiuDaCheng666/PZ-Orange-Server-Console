package cn.zombiecommunity.pzactionisolation;

import zombie.core.ActionManager;
import zombie.core.NetTimedAction;
import zombie.network.GameServer;
import zombie.network.server.AnimEventEmulator;

public final class RuntimeIntegrationTest {
    private RuntimeIntegrationTest() {
    }

    public static void main(String[] args) {
        ActionManager.clear();
        AnimEventEmulator.getInstance().reset();
        TimedActionIsolationRuntime.resetForTest();
        GameServer.server = true;

        NetTimedAction target = new NetTimedAction(126, 10);
        NetTimedAction collision = new NetTimedAction(126, 20);
        NetTimedAction unrelated = new NetTimedAction(125, 30);
        ActionManager.add(target);
        ActionManager.add(collision);
        ActionManager.add(unrelated);

        if (!TimedActionIsolationRuntime.stopExactOnServer(target)) {
            throw new AssertionError("server action was not handled");
        }
        if (ActionManager.contains(target) || !target.stopped) {
            throw new AssertionError("target action was not stopped exactly");
        }
        if (!ActionManager.contains(collision) || collision.stopped) {
            throw new AssertionError("same-ID action owned by another player was modified");
        }
        if (!ActionManager.contains(unrelated) || unrelated.stopped) {
            throw new AssertionError("unrelated action was modified");
        }
        if (AnimEventEmulator.getInstance().removed != target) {
            throw new AssertionError("animation emulator cleanup did not receive the exact action");
        }
        long[] counters = TimedActionIsolationRuntime.countersForTest();
        if (counters[0] != 1 || counters[1] != 1 || counters[2] != 0) {
            throw new AssertionError("unexpected counters exact=" + counters[0]
                    + " protected=" + counters[1] + " failures=" + counters[2]);
        }

        GameServer.server = false;
        if (TimedActionIsolationRuntime.stopExactOnServer(collision)) {
            throw new AssertionError("client mode must fall through to vanilla");
        }
        if (!ActionManager.contains(collision) || collision.stopped) {
            throw new AssertionError("client mode changed the queue");
        }
        System.out.println("PZ timed-action isolation runtime integration tests passed");
    }
}
