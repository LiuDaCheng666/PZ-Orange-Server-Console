package cn.zombiecommunity.pzactionisolation;

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

public final class PZTimedActionIsolationFixAgent {
    private static final String TARGET_CLASS = "zombie/core/ActionManager";
    private static final String TARGET_METHOD = "stop";
    private static final String TARGET_DESCRIPTOR = "(Lzombie/core/Action;)V";
    private static final String RUNTIME =
            "cn/zombiecommunity/pzactionisolation/TimedActionIsolationRuntime";
    private static final Set<String> SUPPORTED_HASHES = Set.of(
            "9b9a993ed9ac7c1b1753ddaf350e7a24a7a69d8f4367b07a6a3b70f919213809");

    private PZTimedActionIsolationFixAgent() {
    }

    public static void premain(String args, Instrumentation instrumentation) {
        try {
            instrumentation.addTransformer(new Transformer(), false);
            System.out.println("[PZTimedActionIsolationFix] agent installed; unsupported classes remain vanilla");
        } catch (Throwable failure) {
            System.err.println("[PZTimedActionIsolationFix] DISABLED setup failed; using vanilla ActionManager: "
                    + failure);
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
                    System.err.println("[PZTimedActionIsolationFix] REFUSED unsupported ActionManager SHA-256="
                            + hash + "; using vanilla class");
                    return null;
                }

                ClassReader reader = new ClassReader(classfileBuffer);
                ClassWriter writer = new SafeClassWriter(
                        reader, ClassWriter.COMPUTE_FRAMES | ClassWriter.COMPUTE_MAXS);
                StopGuardVisitor visitor = new StopGuardVisitor(writer);
                reader.accept(visitor, ClassReader.SKIP_FRAMES);
                if (visitor.hooks != 1) {
                    System.err.println("[PZTimedActionIsolationFix] REFUSED unexpected stop(Action) count="
                            + visitor.hooks + "; using vanilla class");
                    return null;
                }
                System.out.println("[PZTimedActionIsolationFix] ACTIVE exact per-player timed-action stop");
                return writer.toByteArray();
            } catch (Throwable failure) {
                System.err.println("[PZTimedActionIsolationFix] REFUSED transform failed; using vanilla class: "
                        + failure);
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

    private static final class StopGuardVisitor extends ClassVisitor {
        private int hooks;

        private StopGuardVisitor(ClassVisitor delegate) {
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
                    Label vanilla = new Label();
                    output.visitVarInsn(Opcodes.ALOAD, 0);
                    output.visitMethodInsn(
                            Opcodes.INVOKESTATIC,
                            RUNTIME,
                            "stopExactOnServer",
                            "(Ljava/lang/Object;)Z",
                            false);
                    output.visitJumpInsn(Opcodes.IFEQ, vanilla);
                    output.visitInsn(Opcodes.RETURN);
                    output.visitLabel(vanilla);
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
}
