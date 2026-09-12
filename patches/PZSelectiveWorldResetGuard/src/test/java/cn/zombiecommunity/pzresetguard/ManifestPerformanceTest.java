package cn.zombiecommunity.pzresetguard;

import java.nio.file.Files;
import java.nio.file.Path;

public final class ManifestPerformanceTest {
    private ManifestPerformanceTest() {
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 3) {
            throw new IllegalArgumentException("manifest path, expected vehicle count and expected region count are required");
        }
        Path manifest = Path.of(args[0]);
        if (!Files.isRegularFile(manifest)) {
            throw new IllegalArgumentException("manifest does not exist: " + manifest);
        }

        int expectedVehicles = Integer.parseInt(args[1]);
        int expectedRegions = Integer.parseInt(args[2]);
        long startedAt = System.nanoTime();
        SelectiveWorldResetRuntime.ManifestData data = SelectiveWorldResetRuntime.readManifest(manifest);
        long elapsedMillis = (System.nanoTime() - startedAt) / 1_000_000L;

        if (data.vehicleChunks.length != expectedVehicles) {
            throw new AssertionError("vehicle count=" + data.vehicleChunks.length);
        }
        if (data.regionRecords != expectedRegions) {
            throw new AssertionError("region count=" + data.regionRecords);
        }
        System.out.println("PZ reset guard production manifest parsed: bytes=" + Files.size(manifest)
                + " vehicles=" + data.vehicleChunks.length
                + " regionsIgnored=" + data.regionRecords
                + " elapsedMs=" + elapsedMillis);
    }
}
