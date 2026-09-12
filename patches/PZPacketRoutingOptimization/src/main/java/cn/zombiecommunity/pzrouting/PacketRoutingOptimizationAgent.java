package cn.zombiecommunity.pzrouting;

import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.security.MessageDigest;
import java.security.ProtectionDomain;
import java.util.HexFormat;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicBoolean;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

public final class PacketRoutingOptimizationAgent {
    private static final String UDP_CONNECTION = "zombie/core/raknet/UdpConnection";
    private static final String GAME_SERVER = "zombie/network/GameServer";
    private static final String RUNTIME =
            "cn/zombiecommunity/pzrouting/PacketRoutingOptimizationRuntime";
    private static final String UDP_HASH =
            "9c9bb471ff0c3dccdd0e52a3bb3c770327d02f0ad262187f950e660b2730e763";
    private static final Set<String> GAME_SERVER_HASHES = Set.of(
            "339ce837f0e30f45e4b00475ed3026a94e64c52c21d42c9aab81a7655e43c1bd",
            "f6f584c60026d685fdc12012fe5b3e498f599ac02d0fb5b56fa5ae85218c8566");
    private static final AtomicBoolean INSTALLED = new AtomicBoolean();

    private PacketRoutingOptimizationAgent() { }

    public static void premain(String args, Instrumentation instrumentation) {
        install(args, instrumentation, false);
    }

    public static void agentmain(String args, Instrumentation instrumentation) {
        install(args, instrumentation, true);
    }

    private static void install(String args, Instrumentation instrumentation, boolean retransform) {
        if (!INSTALLED.compareAndSet(false, true)) {
            System.out.println("[PZPacketRouting] already installed");
            return;
        }
        Config config = Config.parse(args);
        PacketRoutingOptimizationRuntime.start(
                config.syncIsoObject, config.antibodies, config.antibodiesIntervalMs,
                config.hutchDedup, config.hutchHeartbeatMs, config.hutchCacheMax,
                config.hutchCacheTtlMs, config.farmingDedup, config.farmingHeartbeatMs,
                config.farmingCacheMax, config.farmingCacheTtlMs,
                config.connectionTelemetry, config.telemetryIntervalMs,
                config.telemetryStaleMs, config.reportSeconds);
        Transformer transformer = new Transformer();
        instrumentation.addTransformer(transformer, retransform);
        System.out.println("[PZPacketRouting] agent installed syncIsoObject="
                + config.syncIsoObject + " antibodies=" + config.antibodies
                + " antibodiesIntervalMs=" + config.antibodiesIntervalMs
                + " hutchDedup=" + config.hutchDedup
                + " hutchHeartbeatMs=" + config.hutchHeartbeatMs
                + " hutchCacheMax=" + config.hutchCacheMax
                + " hutchCacheTtlMs=" + config.hutchCacheTtlMs
                + " farmingDedup=" + config.farmingDedup
                + " farmingHeartbeatMs=" + config.farmingHeartbeatMs
                + " farmingCacheMax=" + config.farmingCacheMax
                + " farmingCacheTtlMs=" + config.farmingCacheTtlMs
                + " connectionTelemetry=" + config.connectionTelemetry
                + " telemetryIntervalMs=" + config.telemetryIntervalMs
                + " telemetryStaleMs=" + config.telemetryStaleMs
                + " reportSeconds=" + config.reportSeconds);
        if (!retransform) return;

        Map<String, Class<?>> targets = new ConcurrentHashMap<>();
        for (Class<?> loaded : instrumentation.getAllLoadedClasses()) {
            String name = loaded.getName().replace('.', '/');
            if ((UDP_CONNECTION.equals(name) || GAME_SERVER.equals(name))
                    && instrumentation.isModifiableClass(loaded)) {
                targets.put(name, loaded);
            }
        }
        if (targets.size() != 2) {
            instrumentation.removeTransformer(transformer);
            throw new IllegalStateException("Required classes unavailable: " + targets.keySet());
        }
        try {
            instrumentation.retransformClasses(
                    targets.get(UDP_CONNECTION), targets.get(GAME_SERVER));
        } catch (Throwable failure) {
            instrumentation.removeTransformer(transformer);
            throw new IllegalStateException("Class retransform failed", failure);
        }
        if (transformer.udpHooks != 1 || transformer.commandHooks != 1) {
            instrumentation.removeTransformer(transformer);
            throw new IllegalStateException("Unexpected hook counts udp=" + transformer.udpHooks
                    + " command=" + transformer.commandHooks);
        }
    }

    static byte[] transformForTest(String className, byte[] bytes) {
        return new Transformer().transform(null, className, null, null, bytes);
    }

    private static final class Transformer implements ClassFileTransformer {
        volatile int udpHooks;
        volatile int commandHooks;

        @Override
        public byte[] transform(ClassLoader loader, String className, Class<?> classBeingRedefined,
                ProtectionDomain protectionDomain, byte[] bytes) {
            if (!Set.of(UDP_CONNECTION, GAME_SERVER).contains(className)) return null;
            String hash = sha256(bytes);
            boolean supported = UDP_CONNECTION.equals(className)
                    ? UDP_HASH.equals(hash) : GAME_SERVER_HASHES.contains(hash);
            if (!supported) {
                System.err.println("[PZPacketRouting] REFUSED unsupported " + className
                        + " SHA-256=" + hash + "; using vanilla class");
                return null;
            }
            try {
                ClassReader reader = new ClassReader(bytes);
                ClassWriter writer = new ClassWriter(reader, ClassWriter.COMPUTE_MAXS);
                reader.accept(new RoutingVisitor(writer, className, this), 0);
                int hooks = UDP_CONNECTION.equals(className) ? udpHooks : commandHooks;
                if (hooks != 1) {
                    System.err.println("[PZPacketRouting] REFUSED " + className
                            + " hookCount=" + hooks + "; using vanilla class");
                    return null;
                }
                System.out.println("[PZPacketRouting] ACTIVE " + className
                        + " SHA-256=" + hash);
                return writer.toByteArray();
            } catch (Throwable failure) {
                System.err.println("[PZPacketRouting] REFUSED transform " + className
                        + " failed=" + failure + "; using vanilla class");
                return null;
            }
        }
    }

    private static final class RoutingVisitor extends ClassVisitor {
        private static final String PRIVATE_END_PACKET =
                "(Ljava/nio/ByteBuffer;IIBLjava/util/concurrent/locks/Lock;)V";
        private static final String PLAYER_COMMAND =
                "(Lzombie/characters/IsoPlayer;Ljava/lang/String;Ljava/lang/String;"
                        + "Lse/krka/kahlua/vm/KahluaTable;)V";
        private static final String CONNECTION_COMMAND =
                "(Ljava/lang/String;Ljava/lang/String;Lse/krka/kahlua/vm/KahluaTable;"
                        + "Lzombie/core/raknet/UdpConnection;)V";
        private final String className;
        private final Transformer transformer;

        RoutingVisitor(ClassVisitor output, String className, Transformer transformer) {
            super(Opcodes.ASM9, output);
            this.className = className;
            this.transformer = transformer;
        }

        @Override
        public MethodVisitor visitMethod(int access, String name, String descriptor,
                String signature, String[] exceptions) {
            MethodVisitor output = super.visitMethod(access, name, descriptor, signature, exceptions);
            boolean udpMethod = UDP_CONNECTION.equals(className)
                    && "endPacket".equals(name) && PRIVATE_END_PACKET.equals(descriptor);
            boolean commandMethod = GAME_SERVER.equals(className)
                    && "sendServerCommand".equals(name) && PLAYER_COMMAND.equals(descriptor);
            if (!udpMethod && !commandMethod) return output;
            return new MethodVisitor(Opcodes.ASM9, output) {
                @Override
                public void visitMethodInsn(int opcode, String owner, String method,
                        String calledDescriptor, boolean isInterface) {
                    if (udpMethod && UDP_CONNECTION.equals(owner)
                            && "flipSendUnlock".equals(method)
                            && PRIVATE_END_PACKET.equals(calledDescriptor)) {
                        transformer.udpHooks++;
                        super.visitMethodInsn(Opcodes.INVOKESTATIC, RUNTIME, "sendPacket",
                                "(Lzombie/core/raknet/UdpConnection;Ljava/nio/ByteBuffer;IIB"
                                        + "Ljava/util/concurrent/locks/Lock;)V",
                                false);
                        return;
                    }
                    if (commandMethod && opcode == Opcodes.INVOKESTATIC
                            && GAME_SERVER.equals(owner)
                            && "sendServerCommand".equals(method)
                            && CONNECTION_COMMAND.equals(calledDescriptor)) {
                        transformer.commandHooks++;
                        super.visitMethodInsn(Opcodes.INVOKESTATIC, RUNTIME,
                                "sendServerCommand", CONNECTION_COMMAND, false);
                        return;
                    }
                    super.visitMethodInsn(opcode, owner, method, calledDescriptor, isInterface);
                }
            };
        }
    }

    private static String sha256(byte[] bytes) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));
        } catch (Exception failure) {
            throw new IllegalStateException("SHA-256 unavailable", failure);
        }
    }

    private record Config(boolean syncIsoObject, boolean antibodies,
            long antibodiesIntervalMs, boolean hutchDedup, long hutchHeartbeatMs,
            int hutchCacheMax, long hutchCacheTtlMs, boolean farmingDedup,
            long farmingHeartbeatMs, int farmingCacheMax, long farmingCacheTtlMs,
            boolean connectionTelemetry, long telemetryIntervalMs,
            long telemetryStaleMs, long reportSeconds) {
        static Config parse(String args) {
            boolean syncIsoObject = true;
            boolean antibodies = true;
            long antibodiesIntervalMs = 20_000L;
            boolean hutchDedup = false;
            long hutchHeartbeatMs = 20_000L;
            int hutchCacheMax = 512;
            long hutchCacheTtlMs = 120_000L;
            boolean farmingDedup = true;
            long farmingHeartbeatMs = 300_000L;
            int farmingCacheMax = 32_768;
            long farmingCacheTtlMs = 900_000L;
            boolean connectionTelemetry = true;
            long telemetryIntervalMs = 1_000L;
            long telemetryStaleMs = 900_000L;
            long reportSeconds = 300L;
            if (args != null && !args.isBlank()) {
                for (String token : args.split(",")) {
                    String[] pair = token.split("=", 2);
                    if (pair.length != 2) continue;
                    switch (pair[0].trim()) {
                        case "syncIsoObject" -> syncIsoObject = Boolean.parseBoolean(pair[1].trim());
                        case "antibodies" -> antibodies = Boolean.parseBoolean(pair[1].trim());
                        case "antibodiesIntervalMs" -> antibodiesIntervalMs =
                                Math.max(5_000L, Long.parseLong(pair[1].trim()));
                        case "hutchDedup" -> hutchDedup =
                                Boolean.parseBoolean(pair[1].trim());
                        case "hutchHeartbeatMs" -> hutchHeartbeatMs =
                                Math.max(5_000L, Long.parseLong(pair[1].trim()));
                        case "hutchCacheMax" -> hutchCacheMax =
                                Math.max(64, Math.min(4096, Integer.parseInt(pair[1].trim())));
                        case "hutchCacheTtlMs" -> hutchCacheTtlMs =
                                Math.max(hutchHeartbeatMs * 2L,
                                        Long.parseLong(pair[1].trim()));
                        case "farmingDedup" -> farmingDedup =
                                Boolean.parseBoolean(pair[1].trim());
                        case "farmingHeartbeatMs" -> farmingHeartbeatMs =
                                Math.max(30_000L, Long.parseLong(pair[1].trim()));
                        case "farmingCacheMax" -> farmingCacheMax =
                                Math.max(1024, Math.min(131072, Integer.parseInt(pair[1].trim())));
                        case "farmingCacheTtlMs" -> farmingCacheTtlMs =
                                Math.max(farmingHeartbeatMs * 2L,
                                        Long.parseLong(pair[1].trim()));
                        case "connectionTelemetry" -> connectionTelemetry =
                                Boolean.parseBoolean(pair[1].trim());
                        case "telemetryIntervalMs" -> telemetryIntervalMs =
                                Math.max(500L, Long.parseLong(pair[1].trim()));
                        case "telemetryStaleMs" -> telemetryStaleMs =
                                Math.max(60_000L, Long.parseLong(pair[1].trim()));
                        case "reportSeconds" -> reportSeconds =
                                Math.max(30L, Long.parseLong(pair[1].trim()));
                        default -> { }
                    }
                }
            }
            hutchCacheTtlMs = Math.max(hutchCacheTtlMs, hutchHeartbeatMs * 2L);
            farmingCacheTtlMs = Math.max(farmingCacheTtlMs, farmingHeartbeatMs * 2L);
            return new Config(syncIsoObject, antibodies, antibodiesIntervalMs,
                    hutchDedup, hutchHeartbeatMs, hutchCacheMax,
                    hutchCacheTtlMs, farmingDedup, farmingHeartbeatMs,
                    farmingCacheMax, farmingCacheTtlMs, connectionTelemetry,
                    telemetryIntervalMs, telemetryStaleMs, reportSeconds);
        }
    }
}
