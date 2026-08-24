package cn.zombiecommunity.pzentityguard;

import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.security.MessageDigest;
import java.security.ProtectionDomain;
import java.util.HexFormat;
import java.util.Set;
import java.util.concurrent.atomic.AtomicBoolean;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Label;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

public final class PZEntityRegistrationGuardAgent {
    private static final String TARGET_CLASS = "zombie/entity/EngineEntityManager";
    private static final String TARGET_METHOD = "addEntityInternal";
    private static final String TARGET_DESCRIPTOR = "(Lzombie/entity/GameEntity;)V";
    private static final String RUNTIME =
            "cn/zombiecommunity/pzentityguard/EntityRegistrationGuardRuntime";
    private static final Set<String> SUPPORTED_HASHES = Set.of(
            "532ab439f6dacb5d63c91ab9dbe20b2c6127e79bfaeffd49a1a8f40059517e63");
    private static final AtomicBoolean INSTALLED = new AtomicBoolean();

    private PZEntityRegistrationGuardAgent() {
    }

    public static void premain(String args, Instrumentation instrumentation) {
        if (!INSTALLED.compareAndSet(false, true)) {
            System.out.println("[PZEntityRegistrationGuard] already installed");
            return;
        }
        instrumentation.addTransformer(new Transformer(), false);
        System.out.println("[PZEntityRegistrationGuard] agent installed; unsupported classes remain vanilla");
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

            String hash = sha256(classfileBuffer);
            if (!SUPPORTED_HASHES.contains(hash)) {
                System.err.println("[PZEntityRegistrationGuard] REFUSED unsupported EngineEntityManager.class SHA-256="
                        + hash + "; using vanilla class");
                return null;
            }

            try {
                ClassReader reader = new ClassReader(classfileBuffer);
                ClassWriter writer = new ClassWriter(
                        reader, ClassWriter.COMPUTE_FRAMES | ClassWriter.COMPUTE_MAXS);
                GuardVisitor visitor = new GuardVisitor(writer);
                reader.accept(visitor, ClassReader.SKIP_FRAMES);
                if (visitor.patched != 1) {
                    System.err.println("[PZEntityRegistrationGuard] REFUSED addEntityInternal patch count="
                            + visitor.patched + "; using vanilla class");
                    return null;
                }
                System.out.println("[PZEntityRegistrationGuard] ACTIVE EngineEntityManager.addEntityInternal SHA-256="
                        + hash);
                return writer.toByteArray();
            } catch (Throwable failure) {
                System.err.println("[PZEntityRegistrationGuard] REFUSED transform failed="
                        + failure + "; using vanilla class");
                return null;
            }
        }
    }

    private static final class GuardVisitor extends ClassVisitor {
        private int patched;

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
            patched++;
            return new MethodVisitor(Opcodes.ASM9, output) {
                @Override
                public void visitCode() {
                    super.visitCode();
                    writeGuard(output);
                }
            };
        }
    }

    private static void writeGuard(MethodVisitor output) {
        Label original = new Label();

        output.visitVarInsn(Opcodes.ALOAD, 0);
        output.visitFieldInsn(
                Opcodes.GETFIELD,
                TARGET_CLASS,
                "entitySet",
                "Lzombie/entity/util/ObjectSet;");
        output.visitVarInsn(Opcodes.ALOAD, 1);
        output.visitMethodInsn(
                Opcodes.INVOKEVIRTUAL,
                "zombie/entity/util/ObjectSet",
                "contains",
                "(Ljava/lang/Object;)Z",
                false);
        output.visitJumpInsn(Opcodes.IFEQ, original);

        output.visitVarInsn(Opcodes.ALOAD, 1);
        output.visitFieldInsn(Opcodes.GETFIELD, "zombie/entity/GameEntity", "addedToEngine", "Z");
        output.visitJumpInsn(Opcodes.IFEQ, original);
        output.visitVarInsn(Opcodes.ALOAD, 1);
        output.visitFieldInsn(
                Opcodes.GETFIELD, "zombie/entity/GameEntity", "scheduledForEngineRemoval", "Z");
        output.visitJumpInsn(Opcodes.IFNE, original);
        output.visitVarInsn(Opcodes.ALOAD, 1);
        output.visitFieldInsn(Opcodes.GETFIELD, "zombie/entity/GameEntity", "removingFromEngine", "Z");
        output.visitJumpInsn(Opcodes.IFNE, original);

        output.visitVarInsn(Opcodes.ALOAD, 1);
        output.visitMethodInsn(
                Opcodes.INVOKESTATIC,
                RUNTIME,
                "reportSuppressedDuplicate",
                "(Ljava/lang/Object;)V",
                false);
        output.visitInsn(Opcodes.RETURN);
        output.visitLabel(original);
    }

    private static String sha256(byte[] bytes) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));
        } catch (Exception failure) {
            throw new IllegalStateException("SHA-256 unavailable", failure);
        }
    }
}
