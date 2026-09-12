package cn.zombiecommunity.pzglobalmoddata;

public final class GameClassLoadSmokeTest {
    private GameClassLoadSmokeTest() { }

    public static void main(String[] args) throws Exception {
        Class.forName("zombie.world.moddata.GlobalModData", false,
                ClassLoader.getSystemClassLoader());
        System.out.println("GameClassLoadSmokeTest PASS");
    }
}
