package cn.zombiecommunity.pzanimalLOS;

public final class GameClassLoadSmokeTest {
    private GameClassLoadSmokeTest() { }

    public static void main(String[] args) throws Exception {
        Class.forName("zombie.characters.animals.IsoAnimal", false,
                ClassLoader.getSystemClassLoader());
        System.out.println("GameClassLoadSmokeTest PASS");
    }
}
