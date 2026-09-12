package cn.zombiecommunity.pzactionisolation;

import zombie.core.ActionManager;
import zombie.core.NetTimedAction;
import zombie.network.GameServer;
import zombie.network.packets.GeneralActionPacket;
import zombie.network.server.AnimEventEmulator;

public final class RuntimeIntegrationTest {
    private RuntimeIntegrationTest() {
    }

    public static void main(String[] args) {
        ActionManager.clear();
        AnimEventEmulator.getInstance().reset();
        TimedActionIsolationRuntime.resetForTest();
        GameServer.server = true;

        GeneralActionPacket cancelPacket = new GeneralActionPacket(126, 10);
        NetTimedAction target = new NetTimedAction(126, 10);
        NetTimedAction wrappedTarget = new NetTimedAction(126, 10);
        NetTimedAction collision = new NetTimedAction(126, 20);
        NetTimedAction unrelated = new NetTimedAction(125, 30);
        ActionManager.add(target);
        ActionManager.add(wrappedTarget);
        ActionManager.add(collision);
        ActionManager.add(unrelated);

        if (!TimedActionIsolationRuntime.stopOwnedOnServer(cancelPacket)) {
            throw new AssertionError("server action was not handled");
        }
        if (ActionManager.contains(target) || !target.stopped
                || ActionManager.contains(wrappedTarget) || !wrappedTarget.stopped) {
            throw new AssertionError("owned actions were not stopped by owner and action ID");
        }
        if (!ActionManager.contains(collision) || collision.stopped) {
            throw new AssertionError("same-ID action owned by another player was modified");
        }
        if (!ActionManager.contains(unrelated) || unrelated.stopped) {
            throw new AssertionError("unrelated action was modified");
        }
        if (!AnimEventEmulator.getInstance().removed.contains(target)
                || !AnimEventEmulator.getInstance().removed.contains(wrappedTarget)
                || AnimEventEmulator.getInstance().removed.size() != 2) {
            throw new AssertionError("animation emulator cleanup did not receive both owned actions");
        }

        GeneralActionPacket staleCancel = new GeneralActionPacket(126, 99);
        if (!TimedActionIsolationRuntime.stopOwnedOnServer(staleCancel)) {
            throw new AssertionError("stale server cancellation was not handled");
        }
        if (!ActionManager.contains(collision) || collision.stopped) {
            throw new AssertionError("stale cancellation modified another player's action");
        }

        long[] counters = TimedActionIsolationRuntime.countersForTest();
        if (counters[0] != 2 || counters[1] != 2 || counters[2] != 1 || counters[3] != 0) {
            throw new AssertionError("unexpected counters exact=" + counters[0]
                    + " protected=" + counters[1] + " stale=" + counters[2]
                    + " failures=" + counters[3]);
        }

        GameServer.server = false;
        if (TimedActionIsolationRuntime.stopOwnedOnServer(collision)) {
            throw new AssertionError("client mode must fall through to vanilla");
        }
        if (!ActionManager.contains(collision) || collision.stopped) {
            throw new AssertionError("client mode changed the queue");
        }
        System.out.println("PZ timed-action isolation runtime integration tests passed");
    }
}
