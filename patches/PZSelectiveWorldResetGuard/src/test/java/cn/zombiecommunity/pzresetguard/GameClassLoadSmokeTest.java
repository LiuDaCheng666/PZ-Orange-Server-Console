package cn.zombiecommunity.pzresetguard;

public final class GameClassLoadSmokeTest {
    private GameClassLoadSmokeTest() {
    }

    public static void main(String[] args) throws Exception {
        ClassLoader loader = GameClassLoadSmokeTest.class.getClassLoader();
        Class<?> vehicles = Class.forName("zombie.vehicles.VehiclesDB2", false, loader);
        Class<?> chunk = Class.forName("zombie.iso.IsoChunk", false, loader);
        vehicles.getMethod("init");
        vehicles.getMethod("setChunkSeen", int.class, int.class);
        chunk.getMethod("doLoadGridsquare");
        System.out.println("PZ selective world reset guard real game-class load test passed");
    }
}
