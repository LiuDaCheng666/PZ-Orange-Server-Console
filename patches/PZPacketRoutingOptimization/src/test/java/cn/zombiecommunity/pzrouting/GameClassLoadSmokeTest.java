package cn.zombiecommunity.pzrouting;

public final class GameClassLoadSmokeTest {
    private GameClassLoadSmokeTest() { }

    public static void main(String[] args) throws Exception {
        ClassLoader loader = ClassLoader.getSystemClassLoader();
        Class.forName("zombie.core.raknet.UdpConnection", false, loader);
        Class.forName("zombie.network.GameServer", false, loader);
        System.out.println("GameClassLoadSmokeTest PASS");
    }
}
