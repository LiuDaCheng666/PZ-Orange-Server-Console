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
    private static final String VERSION = "2.1.0";
    private static final String TARGET_CLASS = "zombie/Lua/LuaEventManager";
    private static final String TARGET_METHOD = "triggerEvent";
    private static final String TARGET_DESCRIPTOR =
            "(Ljava/lang/String;Ljava/lang/Object;Ljava/lang/Object;Ljava/lang/Object;Ljava/lang/Object;)V";
    private static final String RUNTIME =
            "cn/zombiecommunity/orangeanticheat/OrangeAntiCheatRuntime";
    private static final Set<String> SUPPORTED_HASHES = Set.of(
            "25bdb166d970f48883b4492ad53d454b61b00435606bc55a3be82306eb52fee3");

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
            if (!TARGET_CLASS.equals(className)) {
                return null;
            }
            try {
                String hash = sha256(classfileBuffer);
                if (!SUPPORTED_HASHES.contains(hash)) {
                    System.err.println("[OrangeAntiCheat] event=guard_disabled version=" + VERSION
                            + " reason=unsupported_lua_event_manager sha256=" + hash);
                    return null;
                }

                ClassReader reader = new ClassReader(classfileBuffer);
                ClassWriter writer = new SafeClassWriter(
                        reader, ClassWriter.COMPUTE_FRAMES | ClassWriter.COMPUTE_MAXS);
                GuardVisitor visitor = new GuardVisitor(writer);
                reader.accept(visitor, ClassReader.SKIP_FRAMES);
                if (visitor.hooks != 1) {
                    System.err.println("[OrangeAntiCheat] event=guard_disabled version=" + VERSION
                            + " reason=unexpected_hook_count count=" + visitor.hooks);
                    return null;
                }
                System.out.println("[OrangeAntiCheat] event=guard_ready version=" + VERSION
                        + " mode=javaagent protected=14");
                return writer.toByteArray();
            } catch (Throwable failure) {
                System.err.println("[OrangeAntiCheat] event=guard_disabled version=" + VERSION
                        + " reason=transform_failed detail=" + safe(failure));
                return null;
            }
        }
    }

    private static final class SafeClassWriter extends ClassWriter {
        private SafeClassWriter(ClassReader reader, int flags) {
            super(reader, flags);
        }

        @Override
        protected String getCommonSuperClass(String type1, String type2) {
            return type1.equals(type2) ? type1 : "java/lang/Object";
        }
    }

    private static final class GuardVisitor extends ClassVisitor {
        private int hooks;

        private GuardVisitor(ClassVisitor delegate) {
            super(Opcodes.ASM9, delegate);
        }

        @Override
        public MethodVisitor visitMethod(
                int access,
                String name,
                String descriptor,
                String signature,
                String[] exceptions) {
            MethodVisitor output = super.visitMethod(access, name, descriptor, signature, exceptions);
            if (!TARGET_METHOD.equals(name) || !TARGET_DESCRIPTOR.equals(descriptor)) {
                return output;
            }
            hooks++;
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

    private static String safe(Throwable failure) {
        String value = failure == null ? "unknown" : failure.getClass().getSimpleName();
        return value.replaceAll("[^A-Za-z0-9_.-]", "_");
    }
}
