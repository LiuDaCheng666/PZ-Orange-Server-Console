package cn.zombiecommunity.orangeanticheat;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

public final class RuntimePolicyTest {
    private RuntimePolicyTest() {
    }

    public static void main(String[] args) {
        expect("UseDebugContextMenu", OrangeAntiCheatRuntime.policyFor("object", "clearContainerExplore"));
        expect("UseDebugContextMenu", OrangeAntiCheatRuntime.policyFor("event", "thunder"));
        expect("UseHealthCheat", OrangeAntiCheatRuntime.policyFor("player", "setWeight"));
        expect("UseHealthCheat", OrangeAntiCheatRuntime.policyFor("player", "onHealthCheat"));
        expect("AuthorizedHealthRelay", OrangeAntiCheatRuntime.policyFor("player", "onHealthCheatCurrentPlayer"));
        expect("OwnPlayerOnly", OrangeAntiCheatRuntime.policyFor("player", "onVehicleSleep"));
        expect("", OrangeAntiCheatRuntime.policyFor("object", "openCloseCurtain"));
        expect(14, protectedCount());
        expect(false, OrangeAntiCheatRuntime.shouldBlock(
                "OnClientCommand", "object", "openCloseCurtain", null, null));
        expect(true, OrangeAntiCheatRuntime.shouldBlock(
                "OnClientCommand", "object", "clearContainerExplore", null, null));
        expect(false, OrangeAntiCheatRuntime.shouldBlock(
                "OnServerCommand", "object", "clearContainerExplore", null, null));
        expect(true, OrangeAntiCheatRuntime.isAllowedItemTransform(
                List.of("Hat_A", "Hat_B"), "Base", "Base.Hat_A", "Base.Hat_B"));
        expect(true, OrangeAntiCheatRuntime.isAllowedItemTransform(
                List.of("OtherMod.Hat_B"), "Base", "Base.Hat_A", "OtherMod.Hat_B"));
        expect(true, OrangeAntiCheatRuntime.isAllowedItemTransform(
                List.of("Hat_B"), "Base", "Base.Hat_A", "Base.Hat_A"));
        expect(false, OrangeAntiCheatRuntime.isAllowedItemTransform(
                List.of("Hat_A", "Hat_B"), "Base", "Base.Hat_A", "Base.Crystal_Large"));
        expect(false, OrangeAntiCheatRuntime.isAllowedItemTransform(
                List.of(), "Base", "Base.Hat_A", "Base.Hat_B"));
        expect(false, OrangeAntiCheatRuntime.isAllowedItemTransform(
                null, "Base", "Base.Hammer", "Base.Crystal_Large"));
        expect(true, OrangeAntiCheatRuntime.isAllowedItemTransform(
                null, "Base", "Base.Hammer", "Base.Hammer"));
        expect(true, OrangeAntiCheatRuntime.shouldRejectItemTransformValues(
                true, true, null, "Base", "Base.Hammer", "Base.GoldBar"));
        expect(false, OrangeAntiCheatRuntime.shouldRejectItemTransformValues(
                true, true, null, "Base", "Base.Hammer", "Base.Hammer"));
        expect(false, OrangeAntiCheatRuntime.shouldRejectItemTransformValues(
                true, true, List.of("Hat_B"), "Base", "Base.Hat_A", "Base.Hat_B"));
        expect(true, OrangeAntiCheatRuntime.shouldRejectItemTransformValues(
                false, true, null, "Base", "Base.Hammer", "Base.Hammer"));
        expect(true, OrangeAntiCheatRuntime.shouldRejectItemTransformValues(
                true, false, null, "Base", "Base.Hammer", "Base.Hammer"));
        expect(false, OrangeAntiCheatRuntime.shouldRejectItemTransformValues(
                false, false, null, "", "", ""));
        expect(true, OrangeAntiCheatRuntime.isSuspiciousHealthIncrease(80.0f, 100.0f));
        expect(false, OrangeAntiCheatRuntime.isSuspiciousHealthIncrease(80.0f, 80.9f));
        expect(false, OrangeAntiCheatRuntime.isSuspiciousHealthIncrease(80.0f, 70.0f));
        expect(true, OrangeAntiCheatRuntime.isSuspiciousHealthIncrease(80.0f, Float.NaN));

        FakeTable table = new FakeTable(Map.of("id", 42.0));
        expect(42L, OrangeAntiCheatRuntime.readNumericField(table, "id"));
        expect(null, OrangeAntiCheatRuntime.readNumericField(new FakeTable(Map.of()), "id"));
        expect("bleeding", OrangeAntiCheatRuntime.readTextField(
                new FakeTable(Map.of("action", "bleeding")), "action"));
        OrangeAntiCheatRuntime.clearHealthRelayTicketsForTest();
        OrangeAntiCheatRuntime.rememberHealthRelay(42L, 3L, "bleeding");
        expect(false, OrangeAntiCheatRuntime.consumeHealthRelay(42L, 4L, "bleeding"));
        expect(false, OrangeAntiCheatRuntime.consumeHealthRelay(43L, 3L, "bleeding"));
        expect(true, OrangeAntiCheatRuntime.consumeHealthRelay(42L, 3L, "bleeding"));
        expect(false, OrangeAntiCheatRuntime.consumeHealthRelay(42L, 3L, "bleeding"));
        System.out.println("RuntimePolicyTest passed");
    }

    private static int protectedCount() {
        String[][] candidates = {
                {"object", "addFireOnSquare"}, {"object", "addSmokeOnSquare"},
                {"object", "addExplosionOnSquare"}, {"object", "addFluidDebug"},
                {"object", "clearContainerExplore"}, {"object", "addWaterContainer"},
                {"object", "removeFluidContainer"}, {"player", "onHealthCheatCurrentPlayer"},
                {"player", "onHealthCheat"}, {"player", "setWeight"}, {"erosion", "disableForSquare"},
                {"event", "thunder"}, {"player", "onVehicleSleep"},
                {"player", "onDropHeavyItem"}
        };
        int count = 0;
        for (String[] candidate : candidates) {
            if (!OrangeAntiCheatRuntime.policyFor(candidate[0], candidate[1]).isEmpty()) {
                count++;
            }
        }
        return count;
    }

    private static void expect(Object expected, Object actual) {
        if (expected == null ? actual != null : !expected.equals(actual)) {
            throw new AssertionError("Expected " + expected + ", got " + actual);
        }
    }

    public static final class FakeTable {
        private final Map<Object, Object> values = new HashMap<>();

        FakeTable(Map<?, ?> source) {
            values.putAll(source);
        }

        public Object rawget(Object key) {
            return values.get(key);
        }
    }
}
