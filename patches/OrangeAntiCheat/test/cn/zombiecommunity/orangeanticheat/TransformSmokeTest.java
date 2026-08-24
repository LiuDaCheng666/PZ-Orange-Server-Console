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
        byte[] luaEventManager;
        byte[] transactionManager;
        byte[] playerHealthPacket;
        byte[] playerDamagePacket;
        try (ZipFile jar = new ZipFile(Path.of(args[0]).toFile())) {
            ZipEntry luaEntry = jar.getEntry("zombie/Lua/LuaEventManager.class");
            ZipEntry transactionEntry = jar.getEntry("zombie/core/TransactionManager.class");
            ZipEntry playerHealthEntry = jar.getEntry(
                    "zombie/network/packets/character/PlayerHealthPacket.class");
            ZipEntry playerDamageEntry = jar.getEntry(
                    "zombie/network/packets/character/PlayerDamagePacket.class");
            if (luaEntry == null) {
                throw new AssertionError("LuaEventManager.class is missing");
            }
            if (transactionEntry == null) {
                throw new AssertionError("TransactionManager.class is missing");
            }
            if (playerHealthEntry == null || playerDamageEntry == null) {
                throw new AssertionError("Player health packet classes are missing");
            }
            luaEventManager = jar.getInputStream(luaEntry).readAllBytes();
            transactionManager = jar.getInputStream(transactionEntry).readAllBytes();
            playerHealthPacket = jar.getInputStream(playerHealthEntry).readAllBytes();
            playerDamagePacket = jar.getInputStream(playerDamageEntry).readAllBytes();
        }

        assertHook(
                "zombie/Lua/LuaEventManager",
                luaEventManager,
                "shouldBlock");
        assertHook(
                "zombie/core/TransactionManager",
                transactionManager,
                "shouldRejectItemTransform");
        assertHook(
                "zombie/network/packets/character/PlayerHealthPacket",
                playerHealthPacket,
                "beforeHealthSync");
        assertHook(
                "zombie/network/packets/character/PlayerHealthPacket",
                playerHealthPacket,
                "afterHealthSync");
        assertHook(
                "zombie/network/packets/character/PlayerDamagePacket",
                playerDamagePacket,
                "beforeHealthSync");
        assertHook(
                "zombie/network/packets/character/PlayerDamagePacket",
                playerDamagePacket,
                "afterHealthSync");

        byte[] unsupported = luaEventManager.clone();
        unsupported[unsupported.length - 1] ^= 1;
        if (OrangeAntiCheatAgent.transformForTest(
                "zombie/Lua/LuaEventManager", unsupported) != null) {
            throw new AssertionError("Unsupported class hash must fail open without transformation");
        }
        System.out.println("TransformSmokeTest passed");
    }

    private static void assertHook(String className, byte[] original, String hookName) {
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
}
