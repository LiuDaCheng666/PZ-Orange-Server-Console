package cn.zombiecommunity.pzresetguard;

import java.io.File;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import zombie.ZomboidFileSystem;
import zombie.iso.IsoChunk;
import zombie.iso.areas.isoregion.IsoRegions;
import zombie.vehicles.VehiclesDB2;

public final class SelectiveWorldResetRuntime {
    static final String MANIFEST_NAME = "orange-selective-reset-guard-v1.txt";
    private static final String HEADER = "PZ_SELECTIVE_RESET_GUARD_V1";
    private static final int MAX_RECORDS = 5_000_000;
    private static final AtomicBoolean LOADED = new AtomicBoolean();
    private static final AtomicBoolean FAILURE_LOGGED = new AtomicBoolean();
    private static final ConcurrentHashMap<Long, Long> PENDING_REGIONS = new ConcurrentHashMap<>();
    private static final AtomicInteger QUEUED_REGIONS = new AtomicInteger();
    private static volatile Method getRegionWorker;
    private static volatile Method readSurroundingChunks;

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
            ManifestData manifest = readManifest(manifestPath);
            for (ChunkCoordinate coordinate : manifest.vehicleChunks) {
                VehiclesDB2.instance.setChunkSeen(coordinate.wx, coordinate.wy);
            }
            for (Map.Entry<Long, Long> entry : manifest.regionEpochs.entrySet()) {
                int wx = unpackX(entry.getKey());
                int wy = unpackY(entry.getKey());
                if (!isRegionCacheFresh(wx, wy, entry.getValue())) {
                    PENDING_REGIONS.put(entry.getKey(), entry.getValue());
                }
            }
            System.out.println("[PZSelectiveResetGuard] ACTIVE manifest=" + manifestPath
                    + " vehicleChunks=" + manifest.vehicleChunks.size()
                    + " regionPending=" + PENDING_REGIONS.size());
        } catch (Throwable failure) {
            System.err.println("[PZSelectiveResetGuard] MANIFEST_FAILED; vanilla world generation remains active: "
                    + failure);
        }
    }

    public static void onChunkLoaded(IsoChunk chunk) {
        if (chunk == null || PENDING_REGIONS.isEmpty()) {
            return;
        }
        long key = pack(chunk.wx, chunk.wy);
        Long epoch = PENDING_REGIONS.get(key);
        if (epoch == null) {
            return;
        }
        try {
            if (isRegionCacheFresh(chunk.wx, chunk.wy, epoch)) {
                PENDING_REGIONS.remove(key, epoch);
                return;
            }
            Method workerAccessor = getRegionWorkerMethod();
            Object worker = workerAccessor.invoke(null);
            if (worker == null) {
                return;
            }
            Method rebuild = getReadSurroundingChunksMethod(worker.getClass());
            rebuild.invoke(worker, chunk.wx, chunk.wy, 1, true, true);
            PENDING_REGIONS.remove(key, epoch);
            int queued = QUEUED_REGIONS.incrementAndGet();
            if (queued == 1 || queued % 1000 == 0) {
                System.out.println("[PZSelectiveResetGuard] region rebuild queued=" + queued
                        + " remaining=" + PENDING_REGIONS.size());
            }
        } catch (Throwable failure) {
            if (FAILURE_LOGGED.compareAndSet(false, true)) {
                System.err.println("[PZSelectiveResetGuard] REGION_REBUILD_FAILED; will retry when chunk reloads: "
                        + failure);
            }
        }
    }

    static ManifestData readManifest(Path path) throws Exception {
        List<String> lines = Files.readAllLines(path, StandardCharsets.UTF_8);
        if (lines.isEmpty() || !HEADER.equals(lines.get(0).strip())) {
            throw new IllegalArgumentException("unsupported reset guard manifest header");
        }
        if (lines.size() - 1 > MAX_RECORDS) {
            throw new IllegalArgumentException("reset guard manifest exceeds record limit");
        }
        List<ChunkCoordinate> vehicleChunks = new ArrayList<>();
        Map<Long, Long> regionEpochs = new HashMap<>();
        for (int index = 1; index < lines.size(); index++) {
            String line = lines.get(index).strip();
            if (line.isEmpty() || line.startsWith("#")) {
                continue;
            }
            String[] fields = line.split("\\t", -1);
            if (fields.length < 3) {
                throw new IllegalArgumentException("invalid record at line " + (index + 1));
            }
            int wx = parseCoordinate(fields[1], index);
            int wy = parseCoordinate(fields[2], index);
            if ("V".equals(fields[0]) && fields.length == 3) {
                vehicleChunks.add(new ChunkCoordinate(wx, wy));
            } else if ("R".equals(fields[0]) && fields.length == 4) {
                long epoch = Long.parseLong(fields[3]);
                if (epoch <= 0L) {
                    throw new IllegalArgumentException("invalid region epoch at line " + (index + 1));
                }
                regionEpochs.put(pack(wx, wy), epoch);
            } else {
                throw new IllegalArgumentException("unknown record at line " + (index + 1));
            }
        }
        return new ManifestData(List.copyOf(vehicleChunks), Map.copyOf(regionEpochs));
    }

    private static int parseCoordinate(String value, int index) {
        int coordinate = Integer.parseInt(value);
        if (coordinate < -1_000_000 || coordinate > 1_000_000) {
            throw new IllegalArgumentException("coordinate out of range at line " + (index + 1));
        }
        return coordinate;
    }

    private static boolean isRegionCacheFresh(int wx, int wy, long epoch) throws Exception {
        Path path = currentSavePath("isoregiondata" + File.separator
                + "datachunk_" + wx + "_" + wy + ".bin");
        return Files.isRegularFile(path) && Files.getLastModifiedTime(path).toMillis() >= epoch;
    }

    private static Path currentSavePath(String relative) {
        return Path.of(ZomboidFileSystem.instance.getFileNameInCurrentSave(relative));
    }

    private static Method getRegionWorkerMethod() throws Exception {
        Method method = getRegionWorker;
        if (method == null) {
            synchronized (SelectiveWorldResetRuntime.class) {
                method = getRegionWorker;
                if (method == null) {
                    method = IsoRegions.class.getDeclaredMethod("getRegionWorker");
                    method.setAccessible(true);
                    getRegionWorker = method;
                }
            }
        }
        return method;
    }

    private static Method getReadSurroundingChunksMethod(Class<?> workerClass) throws Exception {
        Method method = readSurroundingChunks;
        if (method == null) {
            synchronized (SelectiveWorldResetRuntime.class) {
                method = readSurroundingChunks;
                if (method == null) {
                    method = workerClass.getDeclaredMethod(
                            "readSurroundingChunks",
                            int.class,
                            int.class,
                            int.class,
                            boolean.class,
                            boolean.class);
                    method.setAccessible(true);
                    readSurroundingChunks = method;
                }
            }
        }
        return method;
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
        final List<ChunkCoordinate> vehicleChunks;
        final Map<Long, Long> regionEpochs;

        ManifestData(List<ChunkCoordinate> vehicleChunks, Map<Long, Long> regionEpochs) {
            this.vehicleChunks = vehicleChunks;
            this.regionEpochs = regionEpochs;
        }
    }

    static final class ChunkCoordinate {
        final int wx;
        final int wy;

        ChunkCoordinate(int wx, int wy) {
            this.wx = wx;
            this.wy = wy;
        }
    }
}
