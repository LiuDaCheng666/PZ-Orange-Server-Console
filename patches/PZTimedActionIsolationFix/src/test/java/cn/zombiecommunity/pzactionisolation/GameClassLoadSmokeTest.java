package cn.zombiecommunity.pzactionisolation;

public final class GameClassLoadSmokeTest {
    private GameClassLoadSmokeTest() {
    }

    public static void main(String[] args) throws Exception {
        Class<?> actionManager = Class.forName("zombie.core.ActionManager", true,
                GameClassLoadSmokeTest.class.getClassLoader());
        actionManager.getMethod("stop", Class.forName("zombie.core.Action"));
        System.out.println("PZ timed-action isolation real game-class load test passed");
    }
}
