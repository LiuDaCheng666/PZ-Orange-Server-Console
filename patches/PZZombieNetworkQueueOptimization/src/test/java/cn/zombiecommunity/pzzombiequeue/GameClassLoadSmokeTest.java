package cn.zombiecommunity.pzzombiequeue;

public final class GameClassLoadSmokeTest {
    private GameClassLoadSmokeTest() { }

    public static void main(String[] args) throws Exception {
        Class.forName("zombie.popman.NetworkZombiePacker", false,
                ClassLoader.getSystemClassLoader());
        System.out.println("GameClassLoadSmokeTest PASS");
    }
}

