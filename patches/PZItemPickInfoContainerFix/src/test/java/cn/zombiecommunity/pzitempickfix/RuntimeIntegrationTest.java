package cn.zombiecommunity.pzitempickfix;

import zombie.inventory.ItemConfigurator;

public final class RuntimeIntegrationTest {
    private RuntimeIntegrationTest() {
    }

    public static void main(String[] args) {
        ItemConfigurator.registerZone("inventorymale");
        int maleBefore = ItemConfigurator.GetIdForString("inventorymale");
        if (maleBefore < 0 || ItemConfigurator.GetIdForString("inventoryfemale") >= 0) {
            throw new AssertionError("unexpected initial ItemConfigurator state");
        }

        ItemPickInfoContainerRuntime.registerMissingContainerIds();
        int maleAfter = ItemConfigurator.GetIdForString("inventorymale");
        int femaleAfter = ItemConfigurator.GetIdForString("inventoryfemale");
        if (maleAfter != maleBefore || femaleAfter < 0 || femaleAfter == maleAfter) {
            throw new AssertionError("missing or unstable container IDs male="
                    + maleAfter + " female=" + femaleAfter);
        }

        ItemPickInfoContainerRuntime.registerMissingContainerIds();
        if (ItemConfigurator.GetIdForString("inventorymale") != maleAfter
                || ItemConfigurator.GetIdForString("inventoryfemale") != femaleAfter) {
            throw new AssertionError("repeated registration changed IDs");
        }
        System.out.println("PZ ItemPickInfo container runtime integration test passed");
    }
}
