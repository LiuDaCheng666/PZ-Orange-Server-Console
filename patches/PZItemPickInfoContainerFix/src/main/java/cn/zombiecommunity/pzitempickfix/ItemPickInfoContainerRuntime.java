package cn.zombiecommunity.pzitempickfix;

import java.util.concurrent.atomic.AtomicBoolean;
import zombie.inventory.ItemConfigurator;

public final class ItemPickInfoContainerRuntime {
    private static final String MALE = "inventorymale";
    private static final String FEMALE = "inventoryfemale";
    private static final AtomicBoolean LOGGED = new AtomicBoolean();

    private ItemPickInfoContainerRuntime() {
    }

    public static void registerMissingContainerIds() {
        try {
            boolean maleAdded = registerIfMissing(MALE);
            boolean femaleAdded = registerIfMissing(FEMALE);
            int maleId = ItemConfigurator.GetIdForString(MALE);
            int femaleId = ItemConfigurator.GetIdForString(FEMALE);
            if (maleId < 0 || femaleId < 0) {
                System.err.println("[PZItemPickInfoContainerFix] FAILED registration "
                        + "inventorymale=" + maleId + " inventoryfemale=" + femaleId
                        + "; preprocessing continues with vanilla behavior");
                return;
            }
            if (LOGGED.compareAndSet(false, true)) {
                String mode = maleAdded || femaleAdded ? "registered" : "already-present";
                System.out.println("[PZItemPickInfoContainerFix] " + mode
                        + " inventorymale=" + maleId + " inventoryfemale=" + femaleId
                        + " before ItemConfig bucket build");
            }
        } catch (Throwable failure) {
            System.err.println("[PZItemPickInfoContainerFix] FAILED runtime registration; "
                    + "preprocessing continues with vanilla behavior: " + failure);
        }
    }

    private static boolean registerIfMissing(String name) {
        if (ItemConfigurator.GetIdForString(name) >= 0) {
            return false;
        }
        return ItemConfigurator.registerZone(name);
    }
}
