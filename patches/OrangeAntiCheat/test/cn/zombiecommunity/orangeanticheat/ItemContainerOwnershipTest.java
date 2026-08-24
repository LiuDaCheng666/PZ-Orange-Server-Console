package cn.zombiecommunity.orangeanticheat;

import java.lang.reflect.Field;
import sun.misc.Unsafe;
import zombie.characters.IsoPlayer;
import zombie.inventory.InventoryItem;
import zombie.inventory.ItemContainer;

public final class ItemContainerOwnershipTest {
    private ItemContainerOwnershipTest() {
    }

    public static void main(String[] args) throws Exception {
        IsoPlayer player = allocateWithoutConstructor(IsoPlayer.class);
        ItemContainer inventory = new ItemContainer();
        player.setInventory(inventory);

        InventoryItem bag = allocateWithoutConstructor(InventoryItem.class);
        bag.setContainer(inventory);
        inventory.items.add(bag);

        ItemContainer nested = new ItemContainer();
        nested.containingItem = bag;

        if (!inventory.isInCharacterInventory(player)) {
            throw new AssertionError("Direct player inventory must be owned by the player");
        }
        if (!nested.isInCharacterInventory(player)) {
            throw new AssertionError("Nested player container must be owned by the player");
        }
        System.out.println("ItemContainerOwnershipTest passed");
    }

    private static <T> T allocateWithoutConstructor(Class<T> type) throws Exception {
        Field field = Unsafe.class.getDeclaredField("theUnsafe");
        field.setAccessible(true);
        return type.cast(((Unsafe) field.get(null)).allocateInstance(type));
    }
}
