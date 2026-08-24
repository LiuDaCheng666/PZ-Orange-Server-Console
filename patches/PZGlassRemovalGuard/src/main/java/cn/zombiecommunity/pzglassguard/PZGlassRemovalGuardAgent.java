package cn.zombiecommunity.pzglassguard;

import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.security.MessageDigest;
import java.security.ProtectionDomain;
import java.util.HexFormat;
import java.util.Set;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

public final class PZGlassRemovalGuardAgent {
    private static final String TARGET_CLASS = "zombie/iso/IsoGridSquare";
    private static final String TARGET_METHOD = "removeGlassAttachments";
    private static final String TARGET_DESCRIPTOR = "(Lzombie/iso/objects/IsoWindow;)V";
    private static final Set<String> SUPPORTED_HASHES = Set.of(
            "952d24a7b328afb4cc397c155f2c5c25292d3d97bceb8a5c3ac493d8a208fc90",
            "cf5ef9005829d258f6ef28394a9f514350fa8fa1ea5f6209cc7836a656f0b0eb");

    private PZGlassRemovalGuardAgent() {
    }

    public static void premain(String agentArgs, Instrumentation instrumentation) {
        System.out.println("[PZGlassRemovalGuard] Starting bounded glass-attachment cleanup guard.");
        instrumentation.addTransformer(new Transformer(), false);
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
                System.err.println("[PZGlassRemovalGuard] REFUSED: unsupported IsoGridSquare.class SHA-256=" + hash);
                System.err.println("[PZGlassRemovalGuard] The game was updated; the original method remains active.");
                return null;
            }

            try {
                ClassReader reader = new ClassReader(classfileBuffer);
                ClassWriter writer = new ClassWriter(0);
                ReplacementVisitor visitor = new ReplacementVisitor(writer);
                reader.accept(visitor, 0);
                if (!visitor.replaced) {
                    System.err.println("[PZGlassRemovalGuard] REFUSED: target method was not found.");
                    return null;
                }
                System.out.println("[PZGlassRemovalGuard] ACTIVE: IsoGridSquare.removeGlassAttachments is guarded.");
                return writer.toByteArray();
            } catch (Throwable failure) {
                System.err.println("[PZGlassRemovalGuard] REFUSED: bytecode transformation failed: " + failure);
                failure.printStackTrace(System.err);
                return null;
            }
        }
    }

    private static final class ReplacementVisitor extends ClassVisitor {
        private boolean replaced;

        private ReplacementVisitor(ClassVisitor delegate) {
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

            replaced = true;
            return new MethodVisitor(Opcodes.ASM9) {
                @Override
                public void visitEnd() {
                    output.visitCode();
                    output.visitVarInsn(Opcodes.ALOAD, 0);
                    output.visitVarInsn(Opcodes.ALOAD, 1);
                    output.visitMethodInsn(
                            Opcodes.INVOKESTATIC,
                            "cn/zombiecommunity/pzglassguard/GlassAttachmentCleanup",
                            "removeGlassAttachments",
                            "(Lzombie/iso/IsoGridSquare;Lzombie/iso/objects/IsoWindow;)V",
                            false);
                    output.visitInsn(Opcodes.RETURN);
                    output.visitMaxs(2, 2);
                    output.visitEnd();
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
