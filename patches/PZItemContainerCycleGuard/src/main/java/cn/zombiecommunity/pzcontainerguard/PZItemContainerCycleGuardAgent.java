package cn.zombiecommunity.pzcontainerguard;

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

public final class PZItemContainerCycleGuardAgent {
    private static final String TARGET_CLASS = "zombie/inventory/ItemContainer";
    private static final String TARGET_METHOD = "getCharacter";
    private static final String TARGET_DESCRIPTOR = "()Lzombie/characters/IsoGameCharacter;";
    private static final String RUNTIME =
            "cn/zombiecommunity/pzcontainerguard/ItemContainerCycleGuardRuntime";
    private static final Set<String> SUPPORTED_HASHES = Set.of(
            "50d1f1898a24c63437be76c18fdd89b91617911568dcf69a29a7444b2d1c4420");
    private static final AtomicBoolean INSTALLED = new AtomicBoolean();

    private PZItemContainerCycleGuardAgent() {
    }

    public static void premain(String args, Instrumentation instrumentation) {
        if (!INSTALLED.compareAndSet(false, true)) {
            System.out.println("[PZItemContainerCycleGuard] already installed");
            return;
        }
        instrumentation.addTransformer(new Transformer(), false);
        System.out.println("[PZItemContainerCycleGuard] agent installed; unsupported classes remain vanilla");
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
                System.err.println("[PZItemContainerCycleGuard] REFUSED unsupported ItemContainer.class SHA-256="
                        + hash + "; using vanilla class");
                return null;
            }

            try {
                ClassReader reader = new ClassReader(classfileBuffer);
                ClassWriter writer = new SafeClassWriter(
                        reader, ClassWriter.COMPUTE_FRAMES | ClassWriter.COMPUTE_MAXS);
                ReplacementVisitor visitor = new ReplacementVisitor(writer);
                reader.accept(visitor, ClassReader.SKIP_FRAMES);
                if (visitor.replaced != 1) {
                    System.err.println("[PZItemContainerCycleGuard] REFUSED getCharacter replacement count="
                            + visitor.replaced + "; using vanilla class");
                    return null;
                }
                System.out.println("[PZItemContainerCycleGuard] ACTIVE ItemContainer.getCharacter SHA-256=" + hash);
                return writer.toByteArray();
            } catch (Throwable failure) {
                System.err.println("[PZItemContainerCycleGuard] REFUSED transform failed="
                        + failure + "; using vanilla class");
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
            if (type1.equals(type2)) {
                return type1;
            }
            return "java/lang/Object";
        }
    }

    private static final class ReplacementVisitor extends ClassVisitor {
        private int replaced;

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

            replaced++;
            return new MethodVisitor(Opcodes.ASM9) {
                @Override
                public void visitEnd() {
                    writeGuardedMethod(output);
                }
            };
        }
    }

    private static void writeGuardedMethod(MethodVisitor output) {
        Label loop = new Label();
        Label notCharacter = new Label();
        Label noCharacter = new Label();
        Label selfCycle = new Label();
        Label rootCycleCheck = new Label();
        Label previousCycleCheck = new Label();
        Label advance = new Label();
        Label depthLimit = new Label();

        output.visitCode();
        output.visitVarInsn(Opcodes.ALOAD, 0);
        output.visitVarInsn(Opcodes.ASTORE, 1); // current
        output.visitInsn(Opcodes.ACONST_NULL);
        output.visitVarInsn(Opcodes.ASTORE, 2); // previous
        output.visitInsn(Opcodes.ICONST_0);
        output.visitVarInsn(Opcodes.ISTORE, 3); // depth

        output.visitLabel(loop);
        output.visitVarInsn(Opcodes.ALOAD, 1);
        output.visitJumpInsn(Opcodes.IFNULL, noCharacter);
        output.visitVarInsn(Opcodes.ILOAD, 3);
        output.visitIntInsn(Opcodes.BIPUSH, 64);
        output.visitJumpInsn(Opcodes.IF_ICMPGE, depthLimit);

        output.visitVarInsn(Opcodes.ALOAD, 1);
        output.visitMethodInsn(
                Opcodes.INVOKEVIRTUAL,
                TARGET_CLASS,
                "getParent",
                "()Lzombie/iso/IsoObject;",
                false);
        output.visitVarInsn(Opcodes.ASTORE, 4); // parent
        output.visitVarInsn(Opcodes.ALOAD, 4);
        output.visitTypeInsn(Opcodes.INSTANCEOF, "zombie/characters/IsoGameCharacter");
        output.visitJumpInsn(Opcodes.IFEQ, notCharacter);
        output.visitVarInsn(Opcodes.ALOAD, 4);
        output.visitTypeInsn(Opcodes.CHECKCAST, "zombie/characters/IsoGameCharacter");
        output.visitInsn(Opcodes.ARETURN);

        output.visitLabel(notCharacter);
        output.visitVarInsn(Opcodes.ALOAD, 1);
        output.visitFieldInsn(
                Opcodes.GETFIELD,
                TARGET_CLASS,
                "containingItem",
                "Lzombie/inventory/InventoryItem;");
        output.visitVarInsn(Opcodes.ASTORE, 5); // containing item
        output.visitVarInsn(Opcodes.ALOAD, 5);
        output.visitJumpInsn(Opcodes.IFNULL, noCharacter);
        output.visitVarInsn(Opcodes.ALOAD, 5);
        output.visitMethodInsn(
                Opcodes.INVOKEVIRTUAL,
                "zombie/inventory/InventoryItem",
                "getContainer",
                "()Lzombie/inventory/ItemContainer;",
                false);
        output.visitVarInsn(Opcodes.ASTORE, 6); // next
        output.visitVarInsn(Opcodes.ALOAD, 6);
        output.visitJumpInsn(Opcodes.IFNULL, noCharacter);

        output.visitVarInsn(Opcodes.ALOAD, 6);
        output.visitVarInsn(Opcodes.ALOAD, 1);
        output.visitJumpInsn(Opcodes.IF_ACMPNE, rootCycleCheck);
        output.visitJumpInsn(Opcodes.GOTO, selfCycle);

        output.visitLabel(rootCycleCheck);
        output.visitVarInsn(Opcodes.ILOAD, 3);
        output.visitJumpInsn(Opcodes.IFEQ, previousCycleCheck);
        output.visitVarInsn(Opcodes.ALOAD, 6);
        output.visitVarInsn(Opcodes.ALOAD, 0);
        output.visitJumpInsn(Opcodes.IF_ACMPNE, previousCycleCheck);
        output.visitLdcInsn("root-cycle");
        output.visitVarInsn(Opcodes.ILOAD, 3);
        output.visitInsn(Opcodes.ICONST_1);
        output.visitInsn(Opcodes.IADD);
        output.visitMethodInsn(Opcodes.INVOKESTATIC, RUNTIME, "report", "(Ljava/lang/String;I)V", false);
        output.visitJumpInsn(Opcodes.GOTO, noCharacter);

        output.visitLabel(previousCycleCheck);
        output.visitVarInsn(Opcodes.ALOAD, 2);
        output.visitJumpInsn(Opcodes.IFNULL, advance);
        output.visitVarInsn(Opcodes.ALOAD, 6);
        output.visitVarInsn(Opcodes.ALOAD, 2);
        output.visitJumpInsn(Opcodes.IF_ACMPNE, advance);
        output.visitLdcInsn("two-node-cycle");
        output.visitVarInsn(Opcodes.ILOAD, 3);
        output.visitInsn(Opcodes.ICONST_1);
        output.visitInsn(Opcodes.IADD);
        output.visitMethodInsn(Opcodes.INVOKESTATIC, RUNTIME, "report", "(Ljava/lang/String;I)V", false);
        output.visitJumpInsn(Opcodes.GOTO, noCharacter);

        output.visitLabel(advance);
        output.visitVarInsn(Opcodes.ALOAD, 1);
        output.visitVarInsn(Opcodes.ASTORE, 2);
        output.visitVarInsn(Opcodes.ALOAD, 6);
        output.visitVarInsn(Opcodes.ASTORE, 1);
        output.visitIincInsn(3, 1);
        output.visitJumpInsn(Opcodes.GOTO, loop);

        output.visitLabel(selfCycle);
        output.visitLdcInsn("self-cycle");
        output.visitVarInsn(Opcodes.ILOAD, 3);
        output.visitInsn(Opcodes.ICONST_1);
        output.visitInsn(Opcodes.IADD);
        output.visitMethodInsn(Opcodes.INVOKESTATIC, RUNTIME, "report", "(Ljava/lang/String;I)V", false);
        output.visitJumpInsn(Opcodes.GOTO, noCharacter);

        output.visitLabel(depthLimit);
        output.visitLdcInsn("depth-limit");
        output.visitVarInsn(Opcodes.ILOAD, 3);
        output.visitMethodInsn(Opcodes.INVOKESTATIC, RUNTIME, "report", "(Ljava/lang/String;I)V", false);

        output.visitLabel(noCharacter);
        output.visitInsn(Opcodes.ACONST_NULL);
        output.visitInsn(Opcodes.ARETURN);
        output.visitMaxs(0, 0);
        output.visitEnd();
    }

    private static String sha256(byte[] bytes) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));
        } catch (Exception failure) {
            throw new IllegalStateException("SHA-256 unavailable", failure);
        }
    }
}
