package cn.zombiecommunity.pzresetguard;

import java.io.BufferedReader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.atomic.AtomicBoolean;
import zombie.ZomboidFileSystem;
import zombie.vehicles.VehiclesDB2;

public final class SelectiveWorldResetRuntime {
    static final String MANIFEST_NAME = "orange-selective-reset-guard-v1.txt";
    private static final String HEADER = "PZ_SELECTIVE_RESET_GUARD_V1";
    private static final int MAX_RECORDS = 5_000_000;
    private static final AtomicBoolean LOADED = new AtomicBoolean();

    private SelectiveWorldResetRuntime() {
    }

    public static void seedVehicleChunks() {
        if (!LOADED.compareAndSet(false, true)) {
            return;
        }
        try {
            Path manifestPath = currentSavePath(MANIFEST_NAME);
            if (!Files.isRegularFile(manifestPath)) {
                System.out.println("[PZSelectiveResetGuard] ACTIVE no reset manifest; vanilla world generation unchanged");
                return;
            }
            long startedAt = System.nanoTime();
            ManifestData manifest = readManifest(manifestPath);
            for (long coordinate : manifest.vehicleChunks) {
                VehiclesDB2.instance.setChunkSeen(unpackX(coordinate), unpackY(coordinate));
            }
            long elapsedMillis = (System.nanoTime() - startedAt) / 1_000_000L;
            System.out.println("[PZSelectiveResetGuard] ACTIVE manifest=" + manifestPath
                    + " vehicleChunks=" + manifest.vehicleChunks.length
                    + " regionRecordsIgnored=" + manifest.regionRecords
                    + " regionRebuild=vanilla"
                    + " loadMs=" + elapsedMillis);
        } catch (Throwable failure) {
            System.err.println("[PZSelectiveResetGuard] MANIFEST_FAILED; vanilla world generation remains active: "
                    + failure);
        }
    }

    static ManifestData readManifest(Path path) throws Exception {
        long estimatedRecords = Math.min(MAX_RECORDS, Math.max(16L, Files.size(path) / 18L));
        LongArrayBuilder vehicleChunks = new LongArrayBuilder((int) Math.min(estimatedRecords / 2L, 1_500_000L));
        int regionRecords = 0;

        try (BufferedReader reader = Files.newBufferedReader(path, StandardCharsets.UTF_8)) {
            String header = reader.readLine();
            if (header == null || !HEADER.equals(header.strip())) {
                throw new IllegalArgumentException("unsupported reset guard manifest header");
            }

            int lineNumber = 1;
            int records = 0;
            String rawLine;
            while ((rawLine = reader.readLine()) != null) {
                lineNumber++;
                String line = rawLine.strip();
                if (line.isEmpty() || line.startsWith("#")) {
                    continue;
                }
                if (++records > MAX_RECORDS) {
                    throw new IllegalArgumentException("reset guard manifest exceeds record limit");
                }

                int firstTab = line.indexOf('\t');
                int secondTab = firstTab < 0 ? -1 : line.indexOf('\t', firstTab + 1);
                if (firstTab != 1 || secondTab < 0) {
                    throw new IllegalArgumentException("invalid record at line " + lineNumber);
                }
                int wx = parseCoordinate(line, firstTab + 1, secondTab, lineNumber);
                int thirdTab = line.indexOf('\t', secondTab + 1);

                if (line.charAt(0) == 'V' && thirdTab < 0) {
                    int wy = parseCoordinate(line, secondTab + 1, line.length(), lineNumber);
                    vehicleChunks.add(pack(wx, wy));
                } else if (line.charAt(0) == 'R' && thirdTab > secondTab + 1
                        && line.indexOf('\t', thirdTab + 1) < 0) {
                    int wy = parseCoordinate(line, secondTab + 1, thirdTab, lineNumber);
                    long epoch = Long.parseLong(line, thirdTab + 1, line.length(), 10);
                    if (epoch <= 0L) {
                        throw new IllegalArgumentException("invalid region epoch at line " + lineNumber);
                    }
                    regionRecords++;
                } else {
                    throw new IllegalArgumentException("unknown record at line " + lineNumber);
                }
            }
        }
        return new ManifestData(vehicleChunks.toArray(), regionRecords);
    }

    private static int parseCoordinate(String line, int start, int end, int lineNumber) {
        if (start >= end) {
            throw new IllegalArgumentException("missing coordinate at line " + lineNumber);
        }
        int coordinate = Integer.parseInt(line, start, end, 10);
        if (coordinate < -1_000_000 || coordinate > 1_000_000) {
            throw new IllegalArgumentException("coordinate out of range at line " + lineNumber);
        }
        return coordinate;
    }

    private static Path currentSavePath(String relative) {
        return Path.of(ZomboidFileSystem.instance.getFileNameInCurrentSave(relative));
    }

    static long pack(int wx, int wy) {
        return ((long) wx << 32) ^ (wy & 0xffffffffL);
    }

    static int unpackX(long key) {
        return (int) (key >> 32);
    }

    static int unpackY(long key) {
        return (int) key;
    }

    static final class ManifestData {
        final long[] vehicleChunks;
        final int regionRecords;

        ManifestData(long[] vehicleChunks, int regionRecords) {
            this.vehicleChunks = vehicleChunks;
            this.regionRecords = regionRecords;
        }
    }

    private static final class LongArrayBuilder {
        private long[] values;
        private int size;

        LongArrayBuilder(int initialCapacity) {
            values = new long[Math.max(16, initialCapacity)];
        }

        void add(long value) {
            if (size == values.length) {
                long[] expanded = new long[Math.min(MAX_RECORDS, values.length + (values.length >> 1) + 1)];
                System.arraycopy(values, 0, expanded, 0, size);
                values = expanded;
            }
            values[size++] = value;
        }

        long[] toArray() {
            if (size == values.length) {
                return values;
            }
            long[] result = new long[size];
            System.arraycopy(values, 0, result, 0, size);
            return result;
        }
    }
}
