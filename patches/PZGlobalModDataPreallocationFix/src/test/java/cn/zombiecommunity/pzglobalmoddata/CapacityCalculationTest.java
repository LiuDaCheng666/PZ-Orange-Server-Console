package cn.zombiecommunity.pzglobalmoddata;

public final class CapacityCalculationTest {
    private CapacityCalculationTest() { }

    public static void main(String[] args) {
        int mib = 1024 * 1024;
        assertCapacity(1 * mib, -1L, 4 * mib, 256 * mib, 1 * mib);
        assertCapacity(1 * mib, 32L * mib, 4 * mib, 256 * mib, 36 * mib);
        assertCapacity(48 * mib, 32L * mib, 4 * mib, 256 * mib, 48 * mib);
        assertCapacity(1 * mib, 300L * mib, 4 * mib, 256 * mib, 1 * mib);
        assertCapacity(1 * mib, 255L * mib, 4 * mib, 256 * mib, 256 * mib);
        System.out.println("PZ GlobalModData capacity calculation test passed");
    }

    private static void assertCapacity(int requested, long existing, int headroom, int maximum,
            int expected) {
        int actual = GlobalModDataPreallocationRuntime.calculateCapacity(
                requested, existing, headroom, maximum);
        if (actual != expected) {
            throw new AssertionError("capacity expected=" + expected + " actual=" + actual);
        }
    }
}
