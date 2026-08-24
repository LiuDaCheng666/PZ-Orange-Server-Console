package cn.zombiecommunity.pzresetguard;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

public final class ManifestFormatTest {
    private ManifestFormatTest() {
    }

    public static void main(String[] args) throws Exception {
        Path directory = Files.createTempDirectory("pz-reset-guard-test-");
        try {
            Path manifest = directory.resolve(SelectiveWorldResetRuntime.MANIFEST_NAME);
            Files.writeString(
                    manifest,
                    "PZ_SELECTIVE_RESET_GUARD_V1\n"
                            + "V\t10\t20\n"
                            + "V\t-1\t3\n"
                            + "R\t10\t20\t123456789\n",
                    StandardCharsets.UTF_8);
            SelectiveWorldResetRuntime.ManifestData data =
                    SelectiveWorldResetRuntime.readManifest(manifest);
            if (data.vehicleChunks.size() != 2 || data.regionEpochs.size() != 1) {
                throw new AssertionError("unexpected manifest counts");
            }
            long key = SelectiveWorldResetRuntime.pack(10, 20);
            if (!Long.valueOf(123456789L).equals(data.regionEpochs.get(key))) {
                throw new AssertionError("region epoch was not parsed");
            }
            if (SelectiveWorldResetRuntime.unpackX(key) != 10
                    || SelectiveWorldResetRuntime.unpackY(key) != 20) {
                throw new AssertionError("coordinate packing is not reversible");
            }

            Files.writeString(manifest, "wrong\nV\t1\t2\n", StandardCharsets.UTF_8);
            try {
                SelectiveWorldResetRuntime.readManifest(manifest);
                throw new AssertionError("invalid header should fail");
            } catch (IllegalArgumentException expected) {
                // Expected.
            }
        } finally {
            Files.walk(directory)
                    .sorted((left, right) -> right.compareTo(left))
                    .forEach(path -> {
                        try {
                            Files.deleteIfExists(path);
                        } catch (Exception ignored) {
                        }
                    });
        }
        System.out.println("PZ selective world reset guard manifest test passed");
    }
}
