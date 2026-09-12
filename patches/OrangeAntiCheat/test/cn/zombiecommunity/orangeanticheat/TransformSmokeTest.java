package cn.zombiecommunity.orangeanticheat;

import java.nio.file.Path;
import java.util.Arrays;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

public final class TransformSmokeTest {
    private TransformSmokeTest() {
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 1) {
            throw new IllegalArgumentException("Expected projectzomboid.jar path");
        }
        try (ZipFile jar = new ZipFile(Path.of(args[0]).toFile())) {
            assertHook(jar, "zombie/Lua/LuaEventManager", "shouldBlock");
            assertHook(jar, "zombie/core/TransactionManager", "shouldRejectItemTransform");
            assertHook(jar, "zombie/network/packets/character/PlayerHealthPacket", "beforeHealthSync");
            assertHook(jar, "zombie/network/packets/character/PlayerHealthPacket", "afterHealthSync");
            assertHook(jar, "zombie/network/packets/character/PlayerDamagePacket", "beforeHealthSync");
            assertHook(jar, "zombie/network/packets/character/PlayerDamagePacket", "afterHealthSync");
            assertHook(jar, "zombie/network/packets/AddExplosiveTrapPacket", "observeExplosiveTrap");

            byte[] unsupported = readClass(jar, "zombie/Lua/LuaEventManager").clone();
            unsupported[unsupported.length - 1] ^= 1;
            if (OrangeAntiCheatAgent.transformForTest(
                    "zombie/Lua/LuaEventManager", unsupported) != null) {
                throw new AssertionError("Unsupported class hash must fail open without transformation");
            }
        }
        assertRuntimePolicies();
        System.out.println("TransformSmokeTest passed");
    }

    private static void assertRuntimePolicies() {
        String signals = OrangeAntiCheatRuntime.healthSignals(
                1, 5.0f, 50.0f, 53.0f, true, false, 120.0f, 80.0f, 12, 40);
        assertContains(signals, "body_health_increase");
        assertContains(signals, "overall_health_increase");
        assertContains(signals, "infection_cleared");
        assertContains(signals, "infection_time_reduced");
        assertContains(signals, "max_weight_increase");

        String normal = OrangeAntiCheatRuntime.healthSignals(
                0, 0.0f, 50.0f, 50.5f, false, false, 0.0f, 0.0f, 12, 32);
        if (!normal.isEmpty()) {
            throw new AssertionError("Normal health changes must not be reported: " + normal);
        }
        assertContains(OrangeAntiCheatRuntime.healthSignals(
                0, 0.0f, 50.0f, Float.NaN, false, false, 0.0f, 0.0f, 12, 12),
                "non_finite_health");

        OrangeAntiCheatRuntime.clearHealthRelayTicketsForTest();
        OrangeAntiCheatRuntime.rememberHealthRelay(42L, 3L, "Bandage");
        if (!OrangeAntiCheatRuntime.consumeHealthRelay(42L, 3L, "Bandage")) {
            throw new AssertionError("Authorized administrator health relay ticket was not accepted");
        }
        if (OrangeAntiCheatRuntime.consumeHealthRelay(42L, 3L, "Bandage")) {
            throw new AssertionError("Administrator health relay ticket must be single use");
        }
    }

    private static void assertContains(String actual, String expected) {
        if (!Arrays.asList(actual.split(",")).contains(expected)) {
            throw new AssertionError("Expected signal " + expected + " in " + actual);
        }
    }

    private static void assertHook(ZipFile jar, String className, String hookName) throws Exception {
        byte[] original = readClass(jar, className);
        byte[] transformed = OrangeAntiCheatAgent.transformForTest(className, original);
        if (transformed == null || Arrays.equals(original, transformed)) {
            throw new AssertionError("Supported " + className + " was not transformed");
        }
        int[] calls = {0};
        new ClassReader(transformed).accept(new ClassVisitor(Opcodes.ASM9) {
            @Override
            public MethodVisitor visitMethod(
                    int access, String name, String descriptor, String signature, String[] exceptions) {
                MethodVisitor output = super.visitMethod(access, name, descriptor, signature, exceptions);
                return new MethodVisitor(Opcodes.ASM9, output) {
                    @Override
                    public void visitMethodInsn(
                            int opcode, String owner, String method, String desc, boolean isInterface) {
                        if (owner.equals("cn/zombiecommunity/orangeanticheat/OrangeAntiCheatRuntime")
                                && method.equals(hookName)) {
                            calls[0]++;
                        }
                        super.visitMethodInsn(opcode, owner, method, desc, isInterface);
                    }
                };
            }
        }, 0);
        if (calls[0] != 1) {
            throw new AssertionError("Expected one " + hookName + " hook, found " + calls[0]);
        }
    }

    private static byte[] readClass(ZipFile jar, String className) throws Exception {
        ZipEntry entry = jar.getEntry(className + ".class");
        if (entry == null) {
            throw new AssertionError(className + ".class is missing");
        }
        return jar.getInputStream(entry).readAllBytes();
    }
}
