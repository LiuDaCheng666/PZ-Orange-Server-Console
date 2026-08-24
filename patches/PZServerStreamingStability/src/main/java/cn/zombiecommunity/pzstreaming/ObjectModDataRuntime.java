package cn.zombiecommunity.pzstreaming;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.WeakHashMap;
import java.util.concurrent.atomic.LongAdder;
import zombie.core.network.ByteBufferReader;
import zombie.core.raknet.UdpConnection;
import zombie.iso.IsoGridSquare;
import zombie.iso.IsoWorld;
import zombie.network.IConnection;
import zombie.network.PacketTypes;
import zombie.network.packets.ObjectModDataPacket;

public final class ObjectModDataRuntime {
    private static final int TYPE_ISO_OBJECT = 1;
    private static final int TYPE_PLAYER = 2;
    private static final int TYPE_ZOMBIE = 3;
    private static final int TYPE_ANIMAL = 4;
    private static final int TYPE_VEHICLE = 5;
    private static final int TYPE_DEAD_BODY = 6;
    private static final int TYPE_MOVING_OBJECT = 7;
    private static final int TYPE_BUCKETS = 9;
    private static final String[] TYPE_NAMES = {
            "none", "iso-object", "player", "zombie", "animal",
            "vehicle", "dead-body", "moving-object", "other"
    };
    private static final String[] REASON_NAMES = {
            "context-mismatch", "bad-size", "header-parse-failed", "none-target",
            "iso-negative-index", "iso-square-not-loaded", "iso-loaded-index-missing",
            "player-not-registered", "zombie-not-registered", "animal-not-registered",
            "vehicle-not-registered", "dead-body-negative-index",
            "dead-body-square-not-loaded", "dead-body-loaded-index-missing",
            "moving-negative-index", "moving-square-not-loaded",
            "moving-loaded-index-missing", "unsupported-type", "internal-failure"
    };
    private static final int TARGET_WAITING = 0;
    private static final int TARGET_READY = 1;
    private static final int TARGET_STALE = 2;
    private static final Object QUEUE_LOCK = new Object();
    private static final Map<PendingKey, Pending> PENDING = new HashMap<>();
    private static final ArrayDeque<PendingKey> ORDER = new ArrayDeque<>();
    private static final Map<Long, Integer> CONNECTION_COUNTS = new HashMap<>();
    private static final Map<ObjectModDataPacket, Boolean> HANDLED = new WeakHashMap<>();
    private static final Object DIAGNOSTIC_LOCK = new Object();
    private static final Map<String, Long> DIAGNOSTIC_SENDERS = new HashMap<>();
    private static final ThreadLocal<StartContext> START = ThreadLocal.withInitial(StartContext::new);
    private static final LongAdder[] UNRESOLVED_BY_TYPE = adders(TYPE_BUCKETS);
    private static final LongAdder[] UNRESOLVED_BY_REASON = adders(REASON_NAMES.length);
    private static final LongAdder RECEIVED_UNRESOLVED = new LongAdder();
    private static final LongAdder QUEUED = new LongAdder();
    private static final LongAdder DEDUPED = new LongAdder();
    private static final LongAdder APPLIED = new LongAdder();
    private static final LongAdder DROPPED_INVALID = new LongAdder();
    private static final LongAdder DROPPED_STALE = new LongAdder();
    private static final LongAdder DROPPED_EXPIRED = new LongAdder();
    private static final LongAdder DROPPED_OVERFLOW = new LongAdder();
    private static final LongAdder APPLY_FAILURES = new LongAdder();
    private static volatile Config config = Config.defaults();
    private static volatile boolean enabled = true;
    private static volatile boolean drainHookActive;
    private static long pendingBytes;
    private static long lastReportMs;
    private static long lastReportedActivity;

    private ObjectModDataRuntime() {
    }

    public static void configure(String args) {
        config = Config.parse(args);
        enabled = config.objectModData;
        System.out.println("[PZStreaming] config objectModData=" + enabled
                + " maxPending=" + config.maxPending
                + " maxPerConnection=" + config.maxPerConnection
                + " ttlMs=" + config.ttlMs
                + " retryMs=" + config.retryMs
                + " drainMax=" + config.drainMax
                + " drainBudgetMicros=" + config.drainBudgetMicros);
        System.out.println("[PZStreaming] reserved features chunkCache=" + config.chunkCache
                + " integrationBudget=" + config.integrationBudget
                + " prefetch=" + config.prefetch + " (not implemented; forced off)");
        System.out.println("[PZStreaming] ObjectModData diagnostics=type-reason-sender-v1");
    }

    public static boolean isEnabled() {
        return enabled;
    }

    public static void markDrainHookActive() {
        drainHookActive = true;
    }

    public static void begin(
            ObjectModDataPacket packet,
            ByteBufferReader reader,
            IConnection connection) {
        synchronized (HANDLED) {
            HANDLED.remove(packet);
        }
        StartContext context = START.get();
        context.packet = packet;
        context.startPosition = reader.position();
        context.order = reader.bb.order();
    }

    public static void handleUnresolved(
            ObjectModDataPacket packet,
            ByteBufferReader reader,
            IConnection connection) {
        markHandled(packet);
        RECEIVED_UNRESOLVED.increment();
        try {
            StartContext context = START.get();
            if (context.packet != packet) {
                recordDiagnostic(null, connection, 0);
                DROPPED_INVALID.increment();
                reader.position(reader.limit());
                return;
            }
            ByteBuffer source = reader.bb;
            int end = source.limit();
            int start = context.startPosition;
            if (start < 0 || start >= end) {
                recordDiagnostic(null, connection, 1);
                DROPPED_INVALID.increment();
                source.position(end);
                return;
            }
            int size = end - start;
            if (size < 4 || size > config.maxPacketBytes) {
                recordDiagnostic(null, connection, 1);
                DROPPED_INVALID.increment();
                source.position(end);
                return;
            }
            byte[] bytes = new byte[size];
            ByteBuffer copy = source.duplicate();
            copy.position(start);
            copy.limit(end);
            copy.get(bytes);
            source.position(end);

            Header header = Header.parse(bytes, context.order);
            if (header == null) {
                recordDiagnostic(null, connection, 2);
                DROPPED_INVALID.increment();
                return;
            }
            int state = header.isSpatial() && header.objectId >= 0
                    ? targetState(header)
                    : TARGET_STALE;
            recordDiagnostic(header, connection, classifyInitialReason(header, state));
            if (!header.isSpatial() || header.objectId < 0) {
                DROPPED_INVALID.increment();
                return;
            }
            if (state != TARGET_WAITING
                    || !drainHookActive
                    || !(connection instanceof UdpConnection)
                    || !connection.isRelevantTo(header.squareX, header.squareY)) {
                if (state == TARGET_STALE) {
                    DROPPED_STALE.increment();
                } else {
                    DROPPED_INVALID.increment();
                }
                return;
            }
            enqueue(new Pending(
                    new PendingKey(connectionKey(connection), header),
                    header,
                    bytes,
                    context.order,
                    (UdpConnection)connection,
                    System.currentTimeMillis()));
        } catch (Throwable failure) {
            recordDiagnostic(null, connection, 18);
            DROPPED_INVALID.increment();
        }
    }

    public static boolean isHandled(ObjectModDataPacket packet) {
        synchronized (HANDLED) {
            return HANDLED.containsKey(packet);
        }
    }

    public static boolean consumeHandled(ObjectModDataPacket packet) {
        synchronized (HANDLED) {
            return HANDLED.remove(packet) != null;
        }
    }

    public static void drain() {
        if (!enabled || !drainHookActive) {
            return;
        }
        long started = System.nanoTime();
        long deadline = started + config.drainBudgetMicros * 1_000L;
        int scanned = 0;
        int completed = 0;
        while (scanned < config.drainScan
                && completed < config.drainMax
                && System.nanoTime() < deadline) {
            Pending pending = pollPending();
            if (pending == null) {
                break;
            }
            scanned++;
            long now = System.currentTimeMillis();
            if (!pending.connection.isFullyConnected()) {
                finishPending(pending);
                DROPPED_EXPIRED.increment();
                completed++;
                continue;
            }
            if (!pending.connection.isRelevantTo(
                    pending.header.squareX, pending.header.squareY)) {
                finishPending(pending);
                DROPPED_EXPIRED.increment();
                completed++;
                continue;
            }
            if (now - pending.createdMs >= config.ttlMs) {
                finishPending(pending);
                DROPPED_EXPIRED.increment();
                completed++;
                continue;
            }
            if (now < pending.nextAttemptMs) {
                requeue(pending);
                continue;
            }
            int state = targetState(pending.header);
            if (state == TARGET_WAITING) {
                pending.nextAttemptMs = now + config.retryMs;
                requeue(pending);
                continue;
            }
            finishPending(pending);
            completed++;
            if (state == TARGET_STALE) {
                DROPPED_STALE.increment();
                continue;
            }
            apply(pending);
        }
        reportIfDue();
    }

    private static void enqueue(Pending incoming) {
        synchronized (QUEUE_LOCK) {
            Pending previous = PENDING.get(incoming.key);
            if (previous != null) {
                pendingBytes -= previous.bytes.length;
                incoming.createdMs = previous.createdMs;
                PENDING.put(incoming.key, incoming);
                ORDER.remove(incoming.key);
                ORDER.addLast(incoming.key);
                pendingBytes += incoming.bytes.length;
                DEDUPED.increment();
                return;
            }
            while (countForConnection(incoming.key.connectionId) >= config.maxPerConnection) {
                if (!evictOldest(incoming.key.connectionId)) {
                    break;
                }
            }
            while (PENDING.size() >= config.maxPending
                    || pendingBytes + incoming.bytes.length > config.maxPendingBytes) {
                if (!evictOldest(null)) {
                    break;
                }
            }
            if (PENDING.size() >= config.maxPending
                    || pendingBytes + incoming.bytes.length > config.maxPendingBytes) {
                DROPPED_OVERFLOW.increment();
                return;
            }
            PENDING.put(incoming.key, incoming);
            ORDER.addLast(incoming.key);
            pendingBytes += incoming.bytes.length;
            CONNECTION_COUNTS.merge(incoming.key.connectionId, 1, Integer::sum);
            QUEUED.increment();
        }
    }

    private static Pending pollPending() {
        synchronized (QUEUE_LOCK) {
            while (!ORDER.isEmpty()) {
                PendingKey key = ORDER.removeFirst();
                Pending pending = PENDING.get(key);
                if (pending != null) {
                    return pending;
                }
            }
            return null;
        }
    }

    private static void requeue(Pending pending) {
        synchronized (QUEUE_LOCK) {
            if (PENDING.get(pending.key) == pending && !ORDER.contains(pending.key)) {
                ORDER.addLast(pending.key);
            }
        }
    }

    private static void finishPending(Pending pending) {
        synchronized (QUEUE_LOCK) {
            if (PENDING.remove(pending.key, pending)) {
                ORDER.remove(pending.key);
                pendingBytes -= pending.bytes.length;
                decrementConnection(pending.key.connectionId);
            }
        }
    }

    private static boolean evictOldest(Long connectionId) {
        int attempts = ORDER.size();
        while (attempts-- > 0) {
            PendingKey key = ORDER.removeFirst();
            Pending pending = PENDING.get(key);
            if (pending == null) {
                continue;
            }
            if (connectionId != null && key.connectionId != connectionId.longValue()) {
                ORDER.addLast(key);
                continue;
            }
            PENDING.remove(key);
            pendingBytes -= pending.bytes.length;
            decrementConnection(key.connectionId);
            DROPPED_OVERFLOW.increment();
            return true;
        }
        return false;
    }

    private static void apply(Pending pending) {
        try {
            ByteBuffer buffer = ByteBuffer.wrap(pending.bytes).order(pending.order);
            ObjectModDataPacket packet = new ObjectModDataPacket();
            packet.parse(new ByteBufferReader(buffer), pending.connection);
            if (isHandled(packet)) {
                consumeHandled(packet);
                APPLY_FAILURES.increment();
                return;
            }
            if (!packet.isConsistent(pending.connection)) {
                DROPPED_STALE.increment();
                return;
            }
            packet.processServer(PacketTypes.PacketType.ObjectModData, pending.connection);
            APPLIED.increment();
        } catch (Throwable failure) {
            APPLY_FAILURES.increment();
        }
    }

    private static int targetState(Header header) {
        try {
            if (IsoWorld.instance == null || IsoWorld.instance.currentCell == null) {
                return TARGET_WAITING;
            }
            IsoGridSquare square = IsoWorld.instance.currentCell.getGridSquare(
                    header.squareX, header.squareY, header.squareZ);
            if (square == null) {
                return TARGET_WAITING;
            }
            int size;
            if (header.objectType == TYPE_ISO_OBJECT) {
                size = square.getObjects().size();
            } else if (header.objectType == TYPE_DEAD_BODY) {
                size = square.getStaticMovingObjects().size();
            } else {
                size = square.getMovingObjects().size();
            }
            return header.objectId >= 0 && header.objectId < size ? TARGET_READY : TARGET_STALE;
        } catch (Throwable failure) {
            return TARGET_STALE;
        }
    }

    private static void markHandled(ObjectModDataPacket packet) {
        synchronized (HANDLED) {
            HANDLED.put(packet, Boolean.TRUE);
        }
    }

    private static int countForConnection(long connectionId) {
        return CONNECTION_COUNTS.getOrDefault(connectionId, 0);
    }

    private static void decrementConnection(long connectionId) {
        int count = CONNECTION_COUNTS.getOrDefault(connectionId, 0);
        if (count <= 1) {
            CONNECTION_COUNTS.remove(connectionId);
        } else {
            CONNECTION_COUNTS.put(connectionId, count - 1);
        }
    }

    private static long connectionKey(IConnection connection) {
        long guid = connection == null ? 0L : connection.getConnectedGUID();
        return guid != 0L ? guid : Integer.toUnsignedLong(System.identityHashCode(connection));
    }

    private static void reportIfDue() {
        long now = System.currentTimeMillis();
        if (now - lastReportMs < config.reportSeconds * 1_000L) {
            return;
        }
        lastReportMs = now;
        int pendingCount;
        long bytes;
        synchronized (QUEUE_LOCK) {
            pendingCount = PENDING.size();
            bytes = pendingBytes;
        }
        long activity = RECEIVED_UNRESOLVED.sum()
                + QUEUED.sum()
                + DEDUPED.sum()
                + APPLIED.sum()
                + DROPPED_INVALID.sum()
                + DROPPED_STALE.sum()
                + DROPPED_EXPIRED.sum()
                + DROPPED_OVERFLOW.sum()
                + APPLY_FAILURES.sum();
        if (activity == lastReportedActivity && pendingCount == 0) {
            return;
        }
        lastReportedActivity = activity;
        System.out.println("[PZStreaming] ObjectModData summary unresolved="
                + RECEIVED_UNRESOLVED.sum()
                + " queued=" + QUEUED.sum()
                + " deduped=" + DEDUPED.sum()
                + " applied=" + APPLIED.sum()
                + " invalid=" + DROPPED_INVALID.sum()
                + " stale=" + DROPPED_STALE.sum()
                + " expired=" + DROPPED_EXPIRED.sum()
                + " overflow=" + DROPPED_OVERFLOW.sum()
                + " failures=" + APPLY_FAILURES.sum()
                + " pending=" + pendingCount
                + " pendingBytes=" + bytes);
        reportDiagnostics();
    }

    private static int classifyInitialReason(Header header, int state) {
        if (header.objectType == 0) {
            return 3;
        }
        if (header.objectType == TYPE_PLAYER) {
            return 7;
        }
        if (header.objectType == TYPE_ZOMBIE) {
            return 8;
        }
        if (header.objectType == TYPE_ANIMAL) {
            return 9;
        }
        if (header.objectType == TYPE_VEHICLE) {
            return 10;
        }
        if (header.objectType == TYPE_ISO_OBJECT) {
            if (header.objectId < 0) return 4;
            return state == TARGET_WAITING ? 5 : state == TARGET_STALE ? 6 : 18;
        }
        if (header.objectType == TYPE_DEAD_BODY) {
            if (header.objectId < 0) return 11;
            return state == TARGET_WAITING ? 12 : state == TARGET_STALE ? 13 : 18;
        }
        if (header.objectType == TYPE_MOVING_OBJECT) {
            if (header.objectId < 0) return 14;
            return state == TARGET_WAITING ? 15 : state == TARGET_STALE ? 16 : 18;
        }
        return 17;
    }

    private static void recordDiagnostic(Header header, IConnection connection, int reason) {
        int type = header == null ? 0 : header.objectType;
        int bucket = type >= 0 && type < TYPE_BUCKETS - 1 ? type : TYPE_BUCKETS - 1;
        UNRESOLVED_BY_TYPE[bucket].increment();
        if (reason >= 0 && reason < UNRESOLVED_BY_REASON.length) {
            UNRESOLVED_BY_REASON[reason].increment();
        }
        String sender = senderLabel(connection);
        synchronized (DIAGNOSTIC_LOCK) {
            DIAGNOSTIC_SENDERS.merge(sender, 1L, Long::sum);
        }
    }

    private static String senderLabel(IConnection connection) {
        if (connection == null) {
            return "unknown";
        }
        try {
            String username = connection.getUserName();
            if (username == null || username.isBlank()) {
                username = "unknown";
            }
            username = username.replace(',', '_').replace(' ', '_');
            return username + "/" + connection.getSteamId();
        } catch (Throwable ignored) {
            return "guid-" + connectionKey(connection);
        }
    }

    private static void reportDiagnostics() {
        String types = formatAndReset(UNRESOLVED_BY_TYPE, TYPE_NAMES);
        String reasons = formatAndReset(UNRESOLVED_BY_REASON, REASON_NAMES);
        List<Map.Entry<String, Long>> senders;
        synchronized (DIAGNOSTIC_LOCK) {
            senders = new ArrayList<>(DIAGNOSTIC_SENDERS.entrySet());
            DIAGNOSTIC_SENDERS.clear();
        }
        senders.sort(Map.Entry.<String, Long>comparingByValue(Comparator.reverseOrder()));
        StringBuilder topSenders = new StringBuilder();
        for (int index = 0; index < Math.min(5, senders.size()); index++) {
            if (index > 0) topSenders.append(',');
            Map.Entry<String, Long> entry = senders.get(index);
            topSenders.append(entry.getKey()).append(':').append(entry.getValue());
        }
        System.out.println("[PZStreaming] ObjectModData diagnostic interval types=" + types
                + " reasons=" + reasons
                + " topSenders=" + (topSenders.length() == 0 ? "none" : topSenders));
    }

    private static String formatAndReset(LongAdder[] counters, String[] labels) {
        StringBuilder result = new StringBuilder();
        for (int index = 0; index < counters.length; index++) {
            long value = counters[index].sumThenReset();
            if (value == 0) continue;
            if (result.length() > 0) result.append(',');
            result.append(labels[index]).append(':').append(value);
        }
        return result.length() == 0 ? "none" : result.toString();
    }

    private static LongAdder[] adders(int count) {
        LongAdder[] result = new LongAdder[count];
        for (int index = 0; index < count; index++) {
            result[index] = new LongAdder();
        }
        return result;
    }

    private static final class StartContext {
        private ObjectModDataPacket packet;
        private int startPosition;
        private ByteOrder order = ByteOrder.BIG_ENDIAN;
    }

    private static final class Header {
        private final int objectType;
        private final int objectId;
        private final int squareX;
        private final int squareY;
        private final int squareZ;

        private Header(int objectType, int objectId, int squareX, int squareY, int squareZ) {
            this.objectType = objectType;
            this.objectId = objectId;
            this.squareX = squareX;
            this.squareY = squareY;
            this.squareZ = squareZ;
        }

        private static Header parse(byte[] bytes, ByteOrder order) {
            try {
                ByteBuffer buffer = ByteBuffer.wrap(bytes).order(order);
                int type = Byte.toUnsignedInt(buffer.get());
                int id = buffer.getShort();
                if (type == TYPE_ISO_OBJECT || type == TYPE_DEAD_BODY || type == TYPE_MOVING_OBJECT) {
                    if (buffer.remaining() < 10) {
                        return null;
                    }
                    return new Header(
                            type,
                            id,
                            buffer.getInt(),
                            buffer.getInt(),
                            Byte.toUnsignedInt(buffer.get()));
                }
                return new Header(type, id, 0, 0, 0);
            } catch (Throwable failure) {
                return null;
            }
        }

        private boolean isSpatial() {
            return objectType == TYPE_ISO_OBJECT
                    || objectType == TYPE_DEAD_BODY
                    || objectType == TYPE_MOVING_OBJECT;
        }
    }

    private record PendingKey(
            long connectionId,
            int objectType,
            int objectId,
            int squareX,
            int squareY,
            int squareZ) {
        private PendingKey(long connectionId, Header header) {
            this(
                    connectionId,
                    header.objectType,
                    header.objectId,
                    header.squareX,
                    header.squareY,
                    header.squareZ);
        }
    }

    private static final class Pending {
        private final PendingKey key;
        private final Header header;
        private final byte[] bytes;
        private final ByteOrder order;
        private final UdpConnection connection;
        private long createdMs;
        private long nextAttemptMs;

        private Pending(
                PendingKey key,
                Header header,
                byte[] bytes,
                ByteOrder order,
                UdpConnection connection,
                long createdMs) {
            this.key = key;
            this.header = header;
            this.bytes = bytes;
            this.order = order;
            this.connection = connection;
            this.createdMs = createdMs;
            this.nextAttemptMs = createdMs;
        }
    }

    private record Config(
            boolean objectModData,
            boolean chunkCache,
            boolean integrationBudget,
            boolean prefetch,
            int maxPending,
            int maxPerConnection,
            int maxPacketBytes,
            long maxPendingBytes,
            long ttlMs,
            long retryMs,
            int drainMax,
            int drainScan,
            long drainBudgetMicros,
            int reportSeconds) {
        private static Config defaults() {
            return new Config(
                    true, false, false, false,
                    2048, 128, 1024 * 1024, 16L * 1024L * 1024L,
                    5000L, 250L, 64, 128, 1000L, 30);
        }

        private static Config parse(String args) {
            Config defaults = defaults();
            Map<String, String> values = new HashMap<>();
            if (args != null && !args.isBlank()) {
                for (String part : args.split(",")) {
                    String[] pair = part.split("=", 2);
                    if (pair.length == 2) {
                        values.put(pair[0].trim().toLowerCase(), pair[1].trim());
                    }
                }
            }
            return new Config(
                    bool(values, "objectmoddata", defaults.objectModData),
                    false,
                    false,
                    false,
                    integer(values, "maxpending", defaults.maxPending, 64, 8192),
                    integer(values, "maxperconnection", defaults.maxPerConnection, 8, 1024),
                    integer(values, "maxpacketbytes", defaults.maxPacketBytes, 1024, 4 * 1024 * 1024),
                    longValue(values, "maxpendingbytes", defaults.maxPendingBytes, 1024 * 1024L, 64 * 1024 * 1024L),
                    longValue(values, "ttlms", defaults.ttlMs, 500L, 30_000L),
                    longValue(values, "retryms", defaults.retryMs, 50L, 5_000L),
                    integer(values, "drainmax", defaults.drainMax, 1, 256),
                    integer(values, "drainscan", defaults.drainScan, 1, 1024),
                    longValue(values, "drainbudgetmicros", defaults.drainBudgetMicros, 100L, 10_000L),
                    integer(values, "reportseconds", defaults.reportSeconds, 10, 600));
        }

        private static boolean bool(Map<String, String> values, String key, boolean fallback) {
            String value = values.get(key);
            return value == null ? fallback : Boolean.parseBoolean(value);
        }

        private static int integer(
                Map<String, String> values,
                String key,
                int fallback,
                int minimum,
                int maximum) {
            try {
                return Math.max(minimum, Math.min(maximum, Integer.parseInt(values.get(key))));
            } catch (RuntimeException ignored) {
                return fallback;
            }
        }

        private static long longValue(
                Map<String, String> values,
                String key,
                long fallback,
                long minimum,
                long maximum) {
            try {
                return Math.max(minimum, Math.min(maximum, Long.parseLong(values.get(key))));
            } catch (RuntimeException ignored) {
                return fallback;
            }
        }
    }
}
