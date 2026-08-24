package cn.zombiecommunity.orangeanticheat;

import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.security.MessageDigest;
import java.security.ProtectionDomain;
import java.util.HexFormat;
import java.util.Set;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Label;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

public final class OrangeAntiCheatAgent {
    private static final String VERSION = "2.5.0";
    private static final String LUA_EVENT_CLASS = "zombie/Lua/LuaEventManager";
    private static final String LUA_EVENT_METHOD = "triggerEvent";
    private static final String LUA_EVENT_DESCRIPTOR =
            "(Ljava/lang/String;Ljava/lang/Object;Ljava/lang/Object;Ljava/lang/Object;Ljava/lang/Object;)V";
    private static final String TRANSACTION_MANAGER_CLASS = "zombie/core/TransactionManager";
    private static final String TRANSACTION_METHOD = "isConsistent";
    private static final String TRANSACTION_DESCRIPTOR =
            "(ILzombie/inventory/InventoryItem;Lzombie/inventory/ItemContainer;"
                    + "Lzombie/inventory/ItemContainer;Ljava/lang/String;"
                    + "Lzombie/network/packets/ItemTransactionPacket;Lzombie/characters/IsoPlayer;)B";
    private static final String PLAYER_HEALTH_PACKET_CLASS =
            "zombie/network/packets/character/PlayerHealthPacket";
    private static final String PLAYER_DAMAGE_PACKET_CLASS =
            "zombie/network/packets/character/PlayerDamagePacket";
    private static final String HEALTH_PARSE_METHOD = "parse";
    private static final String HEALTH_PARSE_DESCRIPTOR =
            "(Lzombie/core/network/ByteBufferReader;Lzombie/network/IConnection;)V";
    private static final String PLAYER_ID_CLASS = "zombie/network/fields/character/PlayerID";
    private static final String RUNTIME =
            "cn/zombiecommunity/orangeanticheat/OrangeAntiCheatRuntime";
    private static final Set<String> SUPPORTED_LUA_EVENT_HASHES = Set.of(
            "25bdb166d970f48883b4492ad53d454b61b00435606bc55a3be82306eb52fee3");
    private static final Set<String> SUPPORTED_TRANSACTION_MANAGER_HASHES = Set.of(
            "742bf5e9a99ff8f7d95b7a557b387d30e34430aef403f733ff0a919168df1cda");
    private static final Set<String> SUPPORTED_PLAYER_HEALTH_HASHES = Set.of(
            "da2b667034b150dc484c5c878a9b90f2ce09fedbde19708c8c480f601f7fad3a");
    private static final Set<String> SUPPORTED_PLAYER_DAMAGE_HASHES = Set.of(
            "65b4c00e89d7703a65e392bfe525ee734688500e8562209911ce7cb7aba8c83d");

    private OrangeAntiCheatAgent() {
    }

    public static void premain(String args, Instrumentation instrumentation) {
        try {
            instrumentation.addTransformer(new Transformer(), false);
            System.out.println("[OrangeAntiCheat] event=agent_installed version=" + VERSION
                    + " mode=javaagent");
        } catch (Throwable failure) {
            System.err.println("[OrangeAntiCheat] event=guard_disabled version=" + VERSION
                    + " reason=setup_failed detail=" + safe(failure));
        }
    }

    static byte[] transformForTest(String className, byte[] classfileBuffer) {
        return new Transformer().transform(null, className, null, null, classfileBuffer);
    }

    private static final class Transformer implements ClassFileTransformer {
        @Override
        public byte[] transform(
                ClassLoader loader,
                String className,
                Class<?> classBeingRedefined,
                ProtectionDomain protectionDomain,
                byte[] classfileBuffer) {
            if (!LUA_EVENT_CLASS.equals(className)
                    && !TRANSACTION_MANAGER_CLASS.equals(className)
                    && !PLAYER_HEALTH_PACKET_CLASS.equals(className)
                    && !PLAYER_DAMAGE_PACKET_CLASS.equals(className)) {
                return null;
            }
            try {
                String hash = sha256(classfileBuffer);
                Set<String> supportedHashes = supportedHashes(className);
                if (!supportedHashes.contains(hash)) {
                    System.err.println("[OrangeAntiCheat] event=guard_disabled version=" + VERSION
                            + " reason=unsupported_" + classToken(className) + " sha256=" + hash);
                    return null;
                }

                ClassReader reader = new ClassReader(classfileBuffer);
                ClassWriter writer = new ClassWriter(reader, ClassWriter.COMPUTE_MAXS);
                GuardVisitor visitor = new GuardVisitor(writer, className);
                reader.accept(visitor, 0);
                if (visitor.hooks != 1) {
                    System.err.println("[OrangeAntiCheat] event=guard_disabled version=" + VERSION
                            + " reason=unexpected_hook_count class=" + classToken(className)
                            + " count=" + visitor.hooks);
                    return null;
                }
                System.out.println("[OrangeAntiCheat] event=guard_ready version=" + VERSION
                        + " mode=javaagent protected="
                        + featureDescription(className));
                return writer.toByteArray();
            } catch (Throwable failure) {
                System.err.println("[OrangeAntiCheat] event=guard_disabled version=" + VERSION
                        + " reason=transform_failed detail=" + safe(failure));
                return null;
            }
        }
    }

    private static final class GuardVisitor extends ClassVisitor {
        private final String className;
        private int hooks;

        private GuardVisitor(ClassVisitor delegate, String className) {
            super(Opcodes.ASM9, delegate);
            this.className = className;
        }

        @Override
        public MethodVisitor visitMethod(
                int access,
                String name,
                String descriptor,
                String signature,
                String[] exceptions) {
            MethodVisitor output = super.visitMethod(access, name, descriptor, signature, exceptions);
            if (LUA_EVENT_CLASS.equals(className)
                    && LUA_EVENT_METHOD.equals(name)
                    && LUA_EVENT_DESCRIPTOR.equals(descriptor)) {
                hooks++;
                return clientCommandGuard(output);
            }
            if (TRANSACTION_MANAGER_CLASS.equals(className)
                    && TRANSACTION_METHOD.equals(name)
                    && TRANSACTION_DESCRIPTOR.equals(descriptor)) {
                hooks++;
                return itemTransformGuard(output);
            }
            if ((PLAYER_HEALTH_PACKET_CLASS.equals(className)
                    || PLAYER_DAMAGE_PACKET_CLASS.equals(className))
                    && HEALTH_PARSE_METHOD.equals(name)
                    && HEALTH_PARSE_DESCRIPTOR.equals(descriptor)) {
                hooks++;
                return healthSyncGuard(output);
            }
            return output;
        }

        private static MethodVisitor clientCommandGuard(MethodVisitor output) {
            return new MethodVisitor(Opcodes.ASM9, output) {
                @Override
                public void visitCode() {
                    super.visitCode();
                    Label allowed = new Label();
                    output.visitVarInsn(Opcodes.ALOAD, 0);
                    output.visitVarInsn(Opcodes.ALOAD, 1);
                    output.visitVarInsn(Opcodes.ALOAD, 2);
                    output.visitVarInsn(Opcodes.ALOAD, 3);
                    output.visitVarInsn(Opcodes.ALOAD, 4);
                    output.visitMethodInsn(
                            Opcodes.INVOKESTATIC,
                            RUNTIME,
                            "shouldBlock",
                            "(Ljava/lang/Object;Ljava/lang/Object;Ljava/lang/Object;Ljava/lang/Object;Ljava/lang/Object;)Z",
                            false);
                    output.visitJumpInsn(Opcodes.IFEQ, allowed);
                    output.visitInsn(Opcodes.RETURN);
                    output.visitLabel(allowed);
                    output.visitFrame(Opcodes.F_SAME, 0, null, 0, null);
                }
            };
        }

        private static MethodVisitor itemTransformGuard(MethodVisitor output) {
            return new MethodVisitor(Opcodes.ASM9, output) {
                @Override
                public void visitCode() {
                    super.visitCode();
                    Label allowed = new Label();
                    output.visitVarInsn(Opcodes.ILOAD, 0);
                    output.visitVarInsn(Opcodes.ALOAD, 2);
                    output.visitVarInsn(Opcodes.ALOAD, 3);
                    output.visitVarInsn(Opcodes.ALOAD, 4);
                    output.visitVarInsn(Opcodes.ALOAD, 6);
                    output.visitMethodInsn(
                            Opcodes.INVOKESTATIC,
                            RUNTIME,
                            "shouldRejectItemTransform",
                            "(ILjava/lang/Object;Ljava/lang/Object;Ljava/lang/String;Ljava/lang/Object;)Z",
                            false);
                    output.visitJumpInsn(Opcodes.IFEQ, allowed);
                    output.visitInsn(Opcodes.ICONST_1);
                    output.visitInsn(Opcodes.IRETURN);
                    output.visitLabel(allowed);
                    output.visitFrame(Opcodes.F_SAME, 0, null, 0, null);
                }
            };
        }

        private static MethodVisitor healthSyncGuard(MethodVisitor output) {
            return new MethodVisitor(Opcodes.ASM9, output) {
                private boolean playerParsed;

                @Override
                public void visitMethodInsn(
                        int opcode, String owner, String name, String descriptor, boolean isInterface) {
                    super.visitMethodInsn(opcode, owner, name, descriptor, isInterface);
                    if (!playerParsed
                            && PLAYER_ID_CLASS.equals(owner)
                            && HEALTH_PARSE_METHOD.equals(name)
                            && HEALTH_PARSE_DESCRIPTOR.equals(descriptor)) {
                        playerParsed = true;
                        Label allowed = new Label();
                        output.visitVarInsn(Opcodes.ALOAD, 0);
                        output.visitVarInsn(Opcodes.ALOAD, 2);
                        output.visitMethodInsn(
                                Opcodes.INVOKESTATIC,
                                RUNTIME,
                                "beforeHealthSync",
                                "(Ljava/lang/Object;Ljava/lang/Object;)Z",
                                false);
                        output.visitJumpInsn(Opcodes.IFEQ, allowed);
                        output.visitInsn(Opcodes.RETURN);
                        output.visitLabel(allowed);
                        output.visitFrame(Opcodes.F_SAME, 0, null, 0, null);
                    }
                }

                @Override
                public void visitInsn(int opcode) {
                    if (opcode == Opcodes.RETURN) {
                        output.visitVarInsn(Opcodes.ALOAD, 0);
                        output.visitMethodInsn(
                                Opcodes.INVOKESTATIC,
                                RUNTIME,
                                "afterHealthSync",
                                "(Ljava/lang/Object;)V",
                                false);
                    }
                    super.visitInsn(opcode);
                }
            };
        }
    }

    private static Set<String> supportedHashes(String className) {
        if (LUA_EVENT_CLASS.equals(className)) {
            return SUPPORTED_LUA_EVENT_HASHES;
        }
        if (TRANSACTION_MANAGER_CLASS.equals(className)) {
            return SUPPORTED_TRANSACTION_MANAGER_HASHES;
        }
        if (PLAYER_HEALTH_PACKET_CLASS.equals(className)) {
            return SUPPORTED_PLAYER_HEALTH_HASHES;
        }
        return SUPPORTED_PLAYER_DAMAGE_HASHES;
    }

    private static String featureDescription(String className) {
        if (LUA_EVENT_CLASS.equals(className)) {
            return "14 feature=client_commands";
        }
        if (TRANSACTION_MANAGER_CLASS.equals(className)) {
            return "1 feature=item_transform";
        }
        return "1 feature=health_sync_audit class=" + classToken(className);
    }

    private static String sha256(byte[] bytes) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));
        } catch (Exception failure) {
            throw new IllegalStateException("SHA-256 unavailable", failure);
        }
    }

    private static String safe(Throwable failure) {
        String value = failure == null ? "unknown" : failure.getClass().getSimpleName();
        return value.replaceAll("[^A-Za-z0-9_.-]", "_");
    }

    private static String classToken(String className) {
        return className.replace('/', '_').replaceAll("[^A-Za-z0-9_.-]", "_");
    }
}
