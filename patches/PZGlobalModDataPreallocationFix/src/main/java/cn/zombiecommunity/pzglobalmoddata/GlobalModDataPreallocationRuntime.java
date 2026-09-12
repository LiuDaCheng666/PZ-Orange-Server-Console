package cn.zombiecommunity.pzglobalmoddata;

import java.io.File;
import java.nio.ByteBuffer;
import zombie.ZomboidFileSystem;

public final class GlobalModDataPreallocationRuntime {
    private static volatile boolean enabled;
    private static volatile int headroomBytes = 4 * 1024 * 1024;
    private static volatile int maxPreallocateBytes = 256 * 1024 * 1024;

    private GlobalModDataPreallocationRuntime() { }

    static void configure(boolean isEnabled, int configuredHeadroomBytes,
            int configuredMaxPreallocateBytes) {
        enabled = isEnabled;
        headroomBytes = configuredHeadroomBytes;
        maxPreallocateBytes = configuredMaxPreallocateBytes;
    }

    public static ByteBuffer allocate(int requestedCapacity) {
        if (!enabled) return ByteBuffer.allocate(requestedCapacity);
        long existingBytes = -1L;
        int targetCapacity = requestedCapacity;
        try {
            String path = ZomboidFileSystem.instance
                    .getFileNameInCurrentSave("global_mod_data.bin");
            File existing = new File(path);
            if (existing.isFile()) existingBytes = existing.length();
            targetCapacity = calculateCapacity(requestedCapacity, existingBytes,
                    headroomBytes, maxPreallocateBytes);
        } catch (RuntimeException | LinkageError failure) {
            System.err.println("[PZGlobalModDataPreallocation] capacity lookup failed=" + failure
                    + "; using requestedBytes=" + requestedCapacity);
            targetCapacity = requestedCapacity;
        }

        try {
            ByteBuffer buffer = ByteBuffer.allocate(targetCapacity);
            if (targetCapacity > requestedCapacity) {
                long avoidedGrowthSteps = Math.max(0L,
                        (targetCapacity - (long) requestedCapacity + 524_287L) / 524_288L);
                System.out.println("[PZGlobalModDataPreallocation] allocation requestedBytes="
                        + requestedCapacity + " existingBytes=" + existingBytes
                        + " capacityBytes=" + targetCapacity
                        + " avoidedGrowthSteps=" + avoidedGrowthSteps);
            }
            return buffer;
        } catch (OutOfMemoryError exhausted) {
            if (targetCapacity == requestedCapacity) throw exhausted;
            System.err.println("[PZGlobalModDataPreallocation] preallocation failed capacityBytes="
                    + targetCapacity + "; retrying vanilla requestedBytes=" + requestedCapacity);
            return ByteBuffer.allocate(requestedCapacity);
        }
    }

    static int calculateCapacity(int requestedCapacity, long existingBytes,
            int configuredHeadroomBytes, int configuredMaxPreallocateBytes) {
        if (requestedCapacity < 0) throw new IllegalArgumentException("negative requested capacity");
        if (existingBytes < 0L || existingBytes > configuredMaxPreallocateBytes) {
            return requestedCapacity;
        }
        long candidate = existingBytes + Math.max(0L, configuredHeadroomBytes);
        candidate = Math.min(candidate, configuredMaxPreallocateBytes);
        candidate = Math.max(candidate, requestedCapacity);
        return (int) candidate;
    }
}
