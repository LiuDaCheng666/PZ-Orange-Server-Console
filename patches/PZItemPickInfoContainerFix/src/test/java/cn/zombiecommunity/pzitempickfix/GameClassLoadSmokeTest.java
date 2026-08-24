package cn.zombiecommunity.pzitempickfix;

public final class GameClassLoadSmokeTest {
    private GameClassLoadSmokeTest() {
    }

    public static void main(String[] args) throws Exception {
        Class<?> target = Class.forName(
                "zombie.inventory.ItemConfigurator",
                true,
                GameClassLoadSmokeTest.class.getClassLoader());
        target.getMethod("Preprocess");
        target.getMethod("registerZone", String.class);
        target.getMethod("GetIdForString", String.class);
        System.out.println("PZ ItemPickInfo container real game-class load test passed");
    }
}
