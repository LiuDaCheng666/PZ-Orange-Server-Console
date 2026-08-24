package cn.zombiecommunity.orangeanticheat;

public final class GameClassLoadSmokeTest {
    private GameClassLoadSmokeTest() {
    }

    public static void main(String[] args) throws Exception {
        Class.forName("zombie.Lua.LuaEventManager", true, ClassLoader.getSystemClassLoader());
        Class.forName("zombie.core.TransactionManager", true, ClassLoader.getSystemClassLoader());
        Class.forName(
                "zombie.network.packets.character.PlayerHealthPacket",
                true,
                ClassLoader.getSystemClassLoader());
        Class.forName(
                "zombie.network.packets.character.PlayerDamagePacket",
                true,
                ClassLoader.getSystemClassLoader());
        System.out.println("GameClassLoadSmokeTest passed");
    }
}
