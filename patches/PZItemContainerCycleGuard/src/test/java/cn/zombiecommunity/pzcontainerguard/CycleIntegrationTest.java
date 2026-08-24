package cn.zombiecommunity.pzcontainerguard;

import java.lang.reflect.Field;
import sun.misc.Unsafe;
import zombie.inventory.InventoryItem;
import zombie.inventory.ItemContainer;

public final class CycleIntegrationTest {
    private static final Unsafe UNSAFE = loadUnsafe();

    private CycleIntegrationTest() {
    }

    public static void main(String[] args) throws Exception {
        expectNull(new ItemContainer(), "plain root");

        ItemContainer self = new ItemContainer();
        link(self, self);
        expectNull(self, "self cycle");

        ItemContainer twoA = new ItemContainer();
        ItemContainer twoB = new ItemContainer();
        link(twoA, twoB);
        link(twoB, twoA);
        expectNull(twoA, "two-node cycle");

        ItemContainer longA = new ItemContainer();
        ItemContainer longB = new ItemContainer();
        ItemContainer longC = new ItemContainer();
        ItemContainer longD = new ItemContainer();
        link(longA, longB);
        link(longB, longC);
        link(longC, longD);
        link(longD, longB);
        expectNull(longA, "long cycle");

        System.out.println("PZ item-container cycle guard integration tests passed");
    }

    private static void link(ItemContainer from, ItemContainer to) throws InstantiationException {
        InventoryItem item = (InventoryItem) UNSAFE.allocateInstance(InventoryItem.class);
        item.setContainer(to);
        from.containingItem = item;
    }

    private static void expectNull(ItemContainer container, String scenario) {
        long started = System.nanoTime();
        Object character = container.getCharacter();
        long elapsedMillis = (System.nanoTime() - started) / 1_000_000L;
        if (character != null) {
            throw new AssertionError(scenario + " returned a character");
        }
        if (elapsedMillis > 1_000L) {
            throw new AssertionError(scenario + " took " + elapsedMillis + " ms");
        }
    }

    private static Unsafe loadUnsafe() {
        try {
            Field field = Unsafe.class.getDeclaredField("theUnsafe");
            field.setAccessible(true);
            return (Unsafe) field.get(null);
        } catch (ReflectiveOperationException failure) {
            throw new ExceptionInInitializerError(failure);
        }
    }
}
