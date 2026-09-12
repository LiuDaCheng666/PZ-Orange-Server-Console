package cn.zombiecommunity.pzrouting;

import java.nio.ByteBuffer;
import java.util.Arrays;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.LongAdder;
import java.util.concurrent.locks.Lock;
import se.krka.kahlua.vm.KahluaTable;
import zombie.core.raknet.UdpConnection;
import zombie.core.znet.ZNetStatistics;
import zombie.iso.IsoGridSquare;
import zombie.iso.IsoObject;
import zombie.iso.objects.IsoHutch;
import zombie.network.GameServer;
import zombie.network.ServerMap;

public final class PacketRoutingOptimizationRuntime {
    private static final short SYNC_ISO_OBJECT = 190;
    private static final short OBJECT_MOD_DATA = 192;
    private static final String ANTIBODIES_MODULE = "lgd_antibodies";
    private static final String ANTIBODIES_COMMAND = "shareMedicalFile";
    private static final AtomicBoolean STARTED = new AtomicBoolean();
    private static final Map<String, Long> LAST_ANTIBODIES_SEND = new ConcurrentHashMap<>();
    private static final LongAdder ISO_SENT = new LongAdder();
    private static final LongAdder ISO_SKIPPED = new LongAdder();
    private static final LongAdder ISO_SKIPPED_BYTES = new LongAdder();
    private static final LongAdder ANTIBODIES_SENT = new LongAdder();
    private static final LongAdder ANTIBODIES_SKIPPED = new LongAdder();
    private static final LongAdder HUTCH_SENT = new LongAdder();
    private static final LongAdder HUTCH_DUPLICATE_SKIPPED = new LongAdder();
    private static final LongAdder HUTCH_SKIPPED_BYTES = new LongAdder();
    private static final LongAdder HUTCH_FAIL_OPEN = new LongAdder();
    private static final LongAdder FARMING_SENT = new LongAdder();
    private static final LongAdder FARMING_DUPLICATE_SKIPPED = new LongAdder();
    private static final LongAdder FARMING_SKIPPED_BYTES = new LongAdder();
    private static final LongAdder FARMING_FAIL_OPEN = new LongAdder();
    private static final LongAdder TELEMETRY_FAIL_OPEN = new LongAdder();
    private static final Map<Long, ConnectionTelemetry> CONNECTION_TELEMETRY =
            new ConcurrentHashMap<>();
    private static volatile HutchDedupCache hutchCache = new HutchDedupCache(512);
    private static volatile HutchDedupCache farmingCache = new HutchDedupCache(32768);
    private static volatile boolean syncIsoObjectEnabled;
    private static volatile boolean antibodiesEnabled;
    private static volatile long antibodiesIntervalMs;
    private static volatile boolean hutchDedupEnabled;
    private static volatile long hutchHeartbeatMs;
    private static volatile long hutchCacheTtlMs;
    private static volatile boolean farmingDedupEnabled;
    private static volatile long farmingHeartbeatMs;
    private static volatile long farmingCacheTtlMs;
    private static volatile boolean connectionTelemetryEnabled;
    private static volatile long telemetryIntervalMs;
    private static volatile long telemetryStaleMs;

    private PacketRoutingOptimizationRuntime() { }

    public static void start(boolean syncIsoObject, boolean antibodies,
            long intervalMs, boolean hutchDedup, long heartbeatMs,
            int cacheMax, long cacheTtlMs, boolean farmingDedup,
            long farmingHeartbeat, int farmingCacheMax, long farmingCacheTtl,
            boolean connectionTelemetry, long telemetryInterval,
            long telemetryStale, long reportSeconds) {
        syncIsoObjectEnabled = syncIsoObject;
        antibodiesEnabled = antibodies;
        antibodiesIntervalMs = intervalMs;
        hutchDedupEnabled = hutchDedup;
        hutchHeartbeatMs = heartbeatMs;
        hutchCacheTtlMs = cacheTtlMs;
        hutchCache = new HutchDedupCache(cacheMax);
        farmingDedupEnabled = farmingDedup;
        farmingHeartbeatMs = farmingHeartbeat;
        farmingCacheTtlMs = farmingCacheTtl;
        farmingCache = new HutchDedupCache(farmingCacheMax);
        connectionTelemetryEnabled = connectionTelemetry;
        telemetryIntervalMs = telemetryInterval;
        telemetryStaleMs = telemetryStale;
        if (!STARTED.compareAndSet(false, true)) return;
        Thread reporter = new Thread(() -> reportLoop(reportSeconds), "PZ-packet-routing-report");
        reporter.setDaemon(true);
        reporter.setPriority(Thread.MIN_PRIORITY);
        reporter.start();
    }

    public static void sendPacket(UdpConnection connection, ByteBuffer buffer,
            int priority, int reliability, byte ordering, Lock lock) {
        sampleConnection(connection, System.currentTimeMillis());
        int bytes = buffer == null ? 0 : buffer.position();
        if (shouldSkipSyncIsoObject(connection, buffer, bytes)) {
            ISO_SKIPPED.increment();
            ISO_SKIPPED_BYTES.add(bytes);
            lock.unlock();
            return;
        }
        int farmingDecision = farmingPacketDecision(connection, buffer, bytes);
        if (farmingDecision == 2) {
            FARMING_DUPLICATE_SKIPPED.increment();
            FARMING_SKIPPED_BYTES.add(bytes);
            lock.unlock();
            return;
        }
        if (farmingDecision == 1) FARMING_SENT.increment();
        int hutchDecision = hutchPacketDecision(connection, buffer, bytes);
        if (hutchDecision == 2) {
            HUTCH_DUPLICATE_SKIPPED.increment();
            HUTCH_SKIPPED_BYTES.add(bytes);
            lock.unlock();
            return;
        }
        if (hutchDecision == 1) HUTCH_SENT.increment();
        if (isSyncIsoObject(buffer, bytes)) ISO_SENT.increment();
        buffer.flip();
        try {
            connection.getPeer().Send(buffer, priority, reliability, ordering,
                    connection.getConnectedGUID(), false);
        } finally {
            lock.unlock();
        }
    }

    public static void sendServerCommand(String module, String command,
            KahluaTable args, UdpConnection connection) {
        if (shouldSendAntibodies(module, command, args, connection)) {
            if (ANTIBODIES_MODULE.equals(module) && ANTIBODIES_COMMAND.equals(command)) {
                ANTIBODIES_SENT.increment();
            }
            GameServer.sendServerCommand(module, command, args, connection);
        } else {
            ANTIBODIES_SKIPPED.increment();
        }
    }

    private static boolean shouldSkipSyncIsoObject(
            UdpConnection connection, ByteBuffer buffer, int bytes) {
        if (!syncIsoObjectEnabled || connection == null || !connection.isFullyConnected()
                || !isSyncIsoObject(buffer, bytes) || bytes < 15) {
            return false;
        }
        int x = buffer.getInt(3);
        int y = buffer.getInt(7);
        return !connection.isRelevantTo(x, y);
    }

    private static boolean isSyncIsoObject(ByteBuffer buffer, int bytes) {
        return buffer != null && bytes >= 3 && buffer.getShort(1) == SYNC_ISO_OBJECT;
    }

    private static int farmingPacketDecision(
            UdpConnection connection, ByteBuffer buffer, int bytes) {
        if (!farmingDedupEnabled || connection == null || !connection.isFullyConnected()
                || buffer == null || bytes < 16 || buffer.getShort(1) != OBJECT_MOD_DATA
                || buffer.get(3) != 1) {
            return 0;
        }
        try {
            int objectIndex = buffer.getShort(4);
            int x = buffer.getInt(6);
            int y = buffer.getInt(10);
            int z = buffer.get(14);
            IsoGridSquare square = ServerMap.instance.getGridSquare(x, y, z);
            if (square == null || objectIndex < 0 || objectIndex >= square.getObjects().size()) {
                return 0;
            }
            IsoObject object = square.getObjects().get(objectIndex);
            KahluaTable modData = object.getModData();
            if (modData == null
                    || modData.rawget("state") == null
                    || modData.rawget("nbOfGrow") == null
                    || modData.rawget("health") == null
                    || modData.rawget("waterLvl") == null
                    || modData.rawget("objectName") == null) {
                return 0;
            }
            byte[] payload = new byte[bytes];
            ByteBuffer copy = buffer.duplicate();
            copy.position(0);
            copy.limit(bytes);
            copy.get(payload);
            boolean skip = farmingCache.shouldSkip(
                    connection.getConnectedGUID(), x, y, z, objectIndex,
                    payload, System.currentTimeMillis(), farmingHeartbeatMs);
            return skip ? 2 : 1;
        } catch (Throwable failure) {
            FARMING_FAIL_OPEN.increment();
            return 0;
        }
    }

    private static int hutchPacketDecision(
            UdpConnection connection, ByteBuffer buffer, int bytes) {
        if (!hutchDedupEnabled || connection == null || !connection.isFullyConnected()
                || !isSyncIsoObject(buffer, bytes) || bytes < 18) {
            return 0;
        }
        try {
            int x = buffer.getInt(3);
            int y = buffer.getInt(7);
            int z = buffer.getInt(11);
            int objectIndex = buffer.get(15);
            IsoGridSquare square = ServerMap.instance.getGridSquare(x, y, z);
            if (square == null || objectIndex < 0 || objectIndex >= square.getObjects().size()) {
                return 0;
            }
            IsoObject object = square.getObjects().get(objectIndex);
            if (!(object instanceof IsoHutch)) return 0;

            byte[] payload = new byte[bytes];
            ByteBuffer copy = buffer.duplicate();
            copy.position(0);
            copy.limit(bytes);
            copy.get(payload);
            boolean skip = hutchCache.shouldSkip(
                    connection.getConnectedGUID(), x, y, z, objectIndex,
                    payload, System.currentTimeMillis(), hutchHeartbeatMs);
            return skip ? 2 : 1;
        } catch (Throwable failure) {
            HUTCH_FAIL_OPEN.increment();
            return 0;
        }
    }

    private static boolean shouldSendAntibodies(String module, String command,
            KahluaTable args, UdpConnection connection) {
        if (!antibodiesEnabled || !ANTIBODIES_MODULE.equals(module)
                || !ANTIBODIES_COMMAND.equals(command) || args == null || connection == null) {
            return true;
        }
        String source = medicalFileSource(args);
        if (source == null) return true;
        long now = System.currentTimeMillis();
        String key = connection.getConnectedGUID() + ":" + source;
        while (true) {
            Long previous = LAST_ANTIBODIES_SEND.get(key);
            if (previous != null && now - previous < antibodiesIntervalMs) return false;
            if (previous == null) {
                if (LAST_ANTIBODIES_SEND.putIfAbsent(key, now) == null) return true;
            } else if (LAST_ANTIBODIES_SEND.replace(key, previous, now)) {
                return true;
            }
        }
    }

    private static void sampleConnection(UdpConnection connection, long now) {
        if (!connectionTelemetryEnabled || connection == null || !connection.isFullyConnected()) {
            return;
        }
        try {
            long guid = connection.getConnectedGUID();
            ConnectionTelemetry telemetry = CONNECTION_TELEMETRY.computeIfAbsent(
                    guid, ignored -> new ConnectionTelemetry(now));
            telemetry.sample(connection, now, telemetryIntervalMs);
        } catch (Throwable failure) {
            TELEMETRY_FAIL_OPEN.increment();
        }
    }

    private static String medicalFileSource(KahluaTable args) {
        Object medicalFile = args.rawget("medicalFile");
        if (medicalFile instanceof KahluaTable table) {
            Object userName = table.rawget("userName");
            if (userName != null) return "user:" + userName;
        }
        Object playerOnlineId = args.rawget("playerOnlineId");
        return playerOnlineId == null ? null : "id:" + playerOnlineId;
    }

    private static void reportLoop(long reportSeconds) {
        while (true) {
            try {
                Thread.sleep(reportSeconds * 1000L);
                long now = System.currentTimeMillis();
                LAST_ANTIBODIES_SEND.entrySet().removeIf(
                        row -> now - row.getValue() > antibodiesIntervalMs * 4L);
                hutchCache.removeExpired(now, hutchCacheTtlMs);
                farmingCache.removeExpired(now, farmingCacheTtlMs);
                CONNECTION_TELEMETRY.entrySet().removeIf(
                        row -> now - row.getValue().lastSeenAt() > telemetryStaleMs);
                long isoSent = ISO_SENT.sumThenReset();
                long isoSkipped = ISO_SKIPPED.sumThenReset();
                long isoBytes = ISO_SKIPPED_BYTES.sumThenReset();
                long antibodiesSent = ANTIBODIES_SENT.sumThenReset();
                long antibodiesSkipped = ANTIBODIES_SKIPPED.sumThenReset();
                long hutchSent = HUTCH_SENT.sumThenReset();
                long hutchDuplicateSkipped = HUTCH_DUPLICATE_SKIPPED.sumThenReset();
                long hutchSkippedBytes = HUTCH_SKIPPED_BYTES.sumThenReset();
                long hutchFailOpen = HUTCH_FAIL_OPEN.sumThenReset();
                long farmingSent = FARMING_SENT.sumThenReset();
                long farmingDuplicateSkipped = FARMING_DUPLICATE_SKIPPED.sumThenReset();
                long farmingSkippedBytes = FARMING_SKIPPED_BYTES.sumThenReset();
                long farmingFailOpen = FARMING_FAIL_OPEN.sumThenReset();
                long telemetryFailOpen = TELEMETRY_FAIL_OPEN.sumThenReset();
                if (isoSent != 0L || isoSkipped != 0L
                        || antibodiesSent != 0L || antibodiesSkipped != 0L
                        || hutchSent != 0L || hutchDuplicateSkipped != 0L
                        || hutchFailOpen != 0L || farmingSent != 0L
                        || farmingDuplicateSkipped != 0L || farmingFailOpen != 0L) {
                    System.out.println("[PZPacketRouting] summary syncIsoSent=" + isoSent
                            + " syncIsoSkipped=" + isoSkipped
                            + " syncIsoSkippedBytes=" + isoBytes
                            + " antibodiesSent=" + antibodiesSent
                            + " antibodiesSkipped=" + antibodiesSkipped
                            + " throttleKeys=" + LAST_ANTIBODIES_SEND.size()
                            + " hutchSent=" + hutchSent
                            + " hutchDuplicateSkipped=" + hutchDuplicateSkipped
                            + " hutchSkippedBytes=" + hutchSkippedBytes
                            + " hutchFailOpen=" + hutchFailOpen
                            + " hutchCacheSize=" + hutchCache.size()
                            + " farmingSent=" + farmingSent
                            + " farmingDuplicateSkipped=" + farmingDuplicateSkipped
                            + " farmingSkippedBytes=" + farmingSkippedBytes
                            + " farmingFailOpen=" + farmingFailOpen
                            + " farmingCacheSize=" + farmingCache.size()
                            + " telemetryConnections=" + CONNECTION_TELEMETRY.size()
                            + " telemetryFailOpen=" + telemetryFailOpen);
                }
                for (Map.Entry<Long, ConnectionTelemetry> row : CONNECTION_TELEMETRY.entrySet()) {
                    ConnectionTelemetrySnapshot snapshot = row.getValue().snapshotAndReset();
                    if (snapshot == null || !snapshot.isNotable()) continue;
                    System.out.println("[PZPacketRouting] connection guid=" + row.getKey()
                            + " username=" + snapshot.username
                            + " steamId=" + snapshot.steamId
                            + " samples=" + snapshot.samples
                            + " congestionSamples=" + snapshot.congestionSamples
                            + " bandwidthLimitedSamples=" + snapshot.bandwidthLimitedSamples
                            + " maxSendBufferBytes=" + snapshot.maxSendBufferBytes
                            + " maxResendBufferBytes=" + snapshot.maxResendBufferBytes
                            + " maxResendMessages=" + snapshot.maxResendMessages
                            + " maxPacketLoss=" + snapshot.maxPacketLoss);
                }
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                return;
            } catch (Throwable failure) {
                System.err.println("[PZPacketRouting] report failed=" + failure);
            }
        }
    }

    static final class ConnectionTelemetry {
        private volatile long nextSampleAt;
        private volatile long lastSeenAt;
        private String username = "unknown";
        private long steamId;
        private long samples;
        private long congestionSamples;
        private long bandwidthLimitedSamples;
        private long maxSendBufferBytes;
        private long maxResendBufferBytes;
        private long maxResendMessages;
        private double maxPacketLoss;

        ConnectionTelemetry(long now) {
            nextSampleAt = now;
            lastSeenAt = now;
        }

        void sample(UdpConnection connection, long now, long intervalMs) {
            lastSeenAt = now;
            if (now < nextSampleAt) return;
            synchronized (this) {
                if (now < nextSampleAt) return;
                nextSampleAt = now + intervalMs;
                ZNetStatistics statistics = connection.getStatistics();
                if (statistics == null) return;
                String currentName = connection.getUserName();
                if (currentName != null && !currentName.isBlank()) username = currentName;
                steamId = connection.getSteamId();
                samples++;
                if (statistics.isLimitedByCongestionControl) congestionSamples++;
                if (statistics.isLimitedByOutgoingBandwidthLimit) bandwidthLimitedSamples++;
                long sendBytes = (long) Math.ceil(statistics.bytesInSendBufferImmediate
                        + statistics.bytesInSendBufferHigh
                        + statistics.bytesInSendBufferMedium
                        + statistics.bytesInSendBufferLow);
                maxSendBufferBytes = Math.max(maxSendBufferBytes, sendBytes);
                maxResendBufferBytes = Math.max(maxResendBufferBytes,
                        statistics.bytesInResendBuffer);
                maxResendMessages = Math.max(maxResendMessages,
                        statistics.messagesInResendBuffer);
                if (Double.isFinite(statistics.packetlossLastSecond)) {
                    maxPacketLoss = Math.max(maxPacketLoss, statistics.packetlossLastSecond);
                }
            }
        }

        long lastSeenAt() {
            return lastSeenAt;
        }

        synchronized ConnectionTelemetrySnapshot snapshotAndReset() {
            if (samples == 0L) return null;
            ConnectionTelemetrySnapshot result = new ConnectionTelemetrySnapshot(
                    username, steamId, samples, congestionSamples,
                    bandwidthLimitedSamples, maxSendBufferBytes, maxResendBufferBytes,
                    maxResendMessages, maxPacketLoss);
            samples = 0L;
            congestionSamples = 0L;
            bandwidthLimitedSamples = 0L;
            maxSendBufferBytes = 0L;
            maxResendBufferBytes = 0L;
            maxResendMessages = 0L;
            maxPacketLoss = 0.0;
            return result;
        }
    }

    static final class ConnectionTelemetrySnapshot {
        final String username;
        final long steamId;
        final long samples;
        final long congestionSamples;
        final long bandwidthLimitedSamples;
        final long maxSendBufferBytes;
        final long maxResendBufferBytes;
        final long maxResendMessages;
        final double maxPacketLoss;

        ConnectionTelemetrySnapshot(String username, long steamId, long samples,
                long congestionSamples, long bandwidthLimitedSamples,
                long maxSendBufferBytes, long maxResendBufferBytes,
                long maxResendMessages, double maxPacketLoss) {
            this.username = username;
            this.steamId = steamId;
            this.samples = samples;
            this.congestionSamples = congestionSamples;
            this.bandwidthLimitedSamples = bandwidthLimitedSamples;
            this.maxSendBufferBytes = maxSendBufferBytes;
            this.maxResendBufferBytes = maxResendBufferBytes;
            this.maxResendMessages = maxResendMessages;
            this.maxPacketLoss = maxPacketLoss;
        }

        boolean isNotable() {
            return congestionSamples > 0L || bandwidthLimitedSamples > 0L
                    || maxSendBufferBytes >= 65_536L || maxResendBufferBytes >= 16_384L
                    || maxResendMessages >= 32L || maxPacketLoss >= 0.02;
        }
    }

    static final class HutchDedupCache {
        private final int maxEntries;
        private final LinkedHashMap<HutchKey, HutchState> entries =
                new LinkedHashMap<>(64, 0.75f, true);

        HutchDedupCache(int maxEntries) {
            this.maxEntries = maxEntries;
        }

        synchronized boolean shouldSkip(long guid, int x, int y, int z, int objectIndex,
                byte[] payload, long now, long heartbeatMs) {
            HutchKey key = new HutchKey(guid, x, y, z, objectIndex);
            HutchState previous = entries.get(key);
            if (previous != null && Arrays.equals(previous.payload, payload)) {
                previous.lastAccessAt = now;
                if (now - previous.lastSentAt < heartbeatMs) return true;
                previous.lastSentAt = now;
                return false;
            }
            entries.put(key, new HutchState(payload, now, now));
            while (entries.size() > maxEntries) {
                Iterator<HutchKey> iterator = entries.keySet().iterator();
                iterator.next();
                iterator.remove();
            }
            return false;
        }

        synchronized void removeExpired(long now, long ttlMs) {
            entries.entrySet().removeIf(row -> now - row.getValue().lastAccessAt > ttlMs);
        }

        synchronized int size() {
            return entries.size();
        }
    }

    private record HutchKey(long guid, int x, int y, int z, int objectIndex) { }

    private static final class HutchState {
        final byte[] payload;
        long lastSentAt;
        long lastAccessAt;

        HutchState(byte[] payload, long lastSentAt, long lastAccessAt) {
            this.payload = payload;
            this.lastSentAt = lastSentAt;
            this.lastAccessAt = lastAccessAt;
        }
    }
}
