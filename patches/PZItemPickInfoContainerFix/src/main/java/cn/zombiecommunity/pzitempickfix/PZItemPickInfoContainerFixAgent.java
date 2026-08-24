package cn.zombiecommunity.pzitempickfix;

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

public final class PZItemPickInfoContainerFixAgent {
    private static final String TARGET_CLASS = "zombie/inventory/ItemConfigurator";
    private static final String TARGET_METHOD = "Preprocess";
    private static final String TARGET_DESCRIPTOR = "()V";
    private static final String BUCKET_OWNER = "zombie/scripting/ScriptManager";
    private static final String BUCKET_METHOD = "getAllItemConfigs";
    private static final String BUCKET_DESCRIPTOR = "()Ljava/util/ArrayList;";
    private static final String RUNTIME =
            "cn/zombiecommunity/pzitempickfix/ItemPickInfoContainerRuntime";
    private static final Set<String> SUPPORTED_HASHES = Set.of(
            "c5dc2cd0c22e31fb19ae9b068ab1cfcadce46907a6bed6084f61c3f0422115e8");

    private PZItemPickInfoContainerFixAgent() {
    }

    public static void premain(String args, Instrumentation instrumentation) {
        try {
            instrumentation.addTransformer(new Transformer(), false);
            System.out.println("[PZItemPickInfoContainerFix] agent installed; unsupported classes remain vanilla");
        } catch (Throwable failure) {
            System.err.println("[PZItemPickInfoContainerFix] DISABLED setup failed; using vanilla ItemConfigurator: "
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
                    System.err.println("[PZItemPickInfoContainerFix] REFUSED unsupported ItemConfigurator SHA-256="
                            + hash + "; using vanilla class");
                    return null;
                }

                ClassReader reader = new ClassReader(classfileBuffer);
                ClassWriter writer = new SafeClassWriter(
                        reader, ClassWriter.COMPUTE_FRAMES | ClassWriter.COMPUTE_MAXS);
                PatchVisitor visitor = new PatchVisitor(writer);
                reader.accept(visitor, ClassReader.SKIP_FRAMES);
                if (!visitor.isComplete()) {
                    System.err.println("[PZItemPickInfoContainerFix] REFUSED unexpected Preprocess shape "
                            + visitor.describe() + "; using vanilla class");
                    return null;
                }
                System.out.println("[PZItemPickInfoContainerFix] ACTIVE ItemConfigurator.Preprocess hook SHA-256="
                        + hash);
                return writer.toByteArray();
            } catch (Throwable failure) {
                System.err.println("[PZItemPickInfoContainerFix] REFUSED transform failed; "
                        + "using vanilla ItemConfigurator: " + failure);
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

    private static final class PatchVisitor extends ClassVisitor {
        private int targetMethods;
        private int hooks;

        private PatchVisitor(ClassVisitor delegate) {
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
            targetMethods++;
            return new MethodVisitor(Opcodes.ASM9, output) {
                @Override
                public void visitMethodInsn(
                        int opcode,
                        String owner,
                        String methodName,
                        String methodDescriptor,
                        boolean isInterface) {
                    if (opcode == Opcodes.INVOKEVIRTUAL
                            && BUCKET_OWNER.equals(owner)
                            && BUCKET_METHOD.equals(methodName)
                            && BUCKET_DESCRIPTOR.equals(methodDescriptor)) {
                        hooks++;
                        super.visitMethodInsn(
                                Opcodes.INVOKESTATIC,
                                RUNTIME,
                                "registerMissingContainerIds",
                                "()V",
                                false);
                    }
                    super.visitMethodInsn(opcode, owner, methodName, methodDescriptor, isInterface);
                }
            };
        }

        private boolean isComplete() {
            return targetMethods == 1 && hooks == 1;
        }

        private String describe() {
            return "targetMethods=" + targetMethods + ",hooks=" + hooks;
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
