package cn.zombiecommunity.pzrouting;

import java.nio.file.Files;
import java.nio.file.Path;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

public final class TransformSmokeTest {
    private TransformSmokeTest() { }

    public static void main(String[] args) throws Exception {
        if (args.length != 1) throw new IllegalArgumentException("projectzomboid.jar path required");
        check(args[0], "zombie/core/raknet/UdpConnection.class", "sendPacket");
        check(args[0], "zombie/network/GameServer.class", "sendServerCommand");
        checkHutchCache();
        checkTelemetryThresholds();
        System.out.println("PZPacketRoutingOptimization transform smoke test passed");
    }

    private static void check(String jarPath, String resource, String expectedCall) throws Exception {
        byte[] original;
        try (java.util.jar.JarFile jar = new java.util.jar.JarFile(jarPath)) {
            original = jar.getInputStream(jar.getJarEntry(resource)).readAllBytes();
        }
        String className = resource.substring(0, resource.length() - ".class".length());
        byte[] transformed = PacketRoutingOptimizationAgent.transformForTest(className, original);
        if (transformed == null) throw new AssertionError("Transform refused: " + className);
        int[] calls = {0};
        new ClassReader(transformed).accept(new ClassVisitor(Opcodes.ASM9) {
            @Override
            public MethodVisitor visitMethod(int access, String name, String descriptor,
                    String signature, String[] exceptions) {
                return new MethodVisitor(Opcodes.ASM9) {
                    @Override
                    public void visitMethodInsn(int opcode, String owner, String method,
                            String calledDescriptor, boolean isInterface) {
                        if (owner.equals("cn/zombiecommunity/pzrouting/"
                                + "PacketRoutingOptimizationRuntime")
                                && method.equals(expectedCall)) calls[0]++;
                    }
                };
            }
        }, 0);
        if (calls[0] != 1) throw new AssertionError(
                className + " expected one " + expectedCall + " call, got " + calls[0]);
    }

    private static void checkHutchCache() {
        PacketRoutingOptimizationRuntime.HutchDedupCache cache =
                new PacketRoutingOptimizationRuntime.HutchDedupCache(2);
        byte[] first = {1, 2, 3};
        byte[] changed = {1, 2, 4};
        if (cache.shouldSkip(10L, 1, 2, 0, 3, first, 1_000L, 20_000L)) {
            throw new AssertionError("first hutch packet must be sent");
        }
        if (!cache.shouldSkip(10L, 1, 2, 0, 3, first.clone(), 2_000L, 20_000L)) {
            throw new AssertionError("exact duplicate must be skipped");
        }
        if (cache.shouldSkip(10L, 1, 2, 0, 3, changed, 3_000L, 20_000L)) {
            throw new AssertionError("changed hutch packet must be sent");
        }
        if (cache.shouldSkip(10L, 1, 2, 0, 3, changed.clone(), 23_000L, 20_000L)) {
            throw new AssertionError("heartbeat hutch packet must be sent");
        }
        if (!cache.shouldSkip(10L, 1, 2, 0, 3, changed.clone(), 24_000L, 20_000L)) {
            throw new AssertionError("post-heartbeat duplicate must be skipped");
        }
    }

    private static void checkTelemetryThresholds() {
        PacketRoutingOptimizationRuntime.ConnectionTelemetrySnapshot quiet =
                new PacketRoutingOptimizationRuntime.ConnectionTelemetrySnapshot(
                        "quiet", 1L, 10L, 0L, 0L, 1024L, 1024L, 2L, 0.01);
        if (quiet.isNotable()) throw new AssertionError("quiet connection must not be reported");

        PacketRoutingOptimizationRuntime.ConnectionTelemetrySnapshot congested =
                new PacketRoutingOptimizationRuntime.ConnectionTelemetrySnapshot(
                        "busy", 2L, 10L, 1L, 0L, 1024L, 1024L, 2L, 0.01);
        if (!congested.isNotable()) {
            throw new AssertionError("congested connection must be reported");
        }

        PacketRoutingOptimizationRuntime.ConnectionTelemetrySnapshot resendBacklog =
                new PacketRoutingOptimizationRuntime.ConnectionTelemetrySnapshot(
                        "resend", 3L, 10L, 0L, 0L, 1024L, 16384L, 32L, 0.01);
        if (!resendBacklog.isNotable()) {
            throw new AssertionError("resend backlog must be reported");
        }
    }
}
