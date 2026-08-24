public final class GlassGuardSmokeTest {
    private GlassGuardSmokeTest() {
    }

    public static void main(String[] args) throws Exception {
        Class<?> square = Class.forName("zombie.iso.IsoGridSquare", false,
                GlassGuardSmokeTest.class.getClassLoader());
        Class<?> window = Class.forName("zombie.iso.objects.IsoWindow", false,
                GlassGuardSmokeTest.class.getClassLoader());
        square.getDeclaredMethod("removeGlassAttachments", window);
        System.out.println("[GlassGuardSmokeTest] PASS");
    }
}
