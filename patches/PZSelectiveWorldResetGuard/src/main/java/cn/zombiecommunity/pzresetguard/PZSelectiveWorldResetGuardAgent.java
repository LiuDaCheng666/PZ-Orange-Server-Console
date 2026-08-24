package cn.zombiecommunity.pzresetguard;

import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.security.MessageDigest;
import java.security.ProtectionDomain;
import java.util.HexFormat;
import java.util.Map;
import java.util.Set;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

public final class PZSelectiveWorldResetGuardAgent {
    private static final String VEHICLES_DB = "zombie/vehicles/VehiclesDB2";
    private static final String ISO_CHUNK = "zombie/iso/IsoChunk";
    private static final String RUNTIME =
            "cn/zombiecommunity/pzresetguard/SelectiveWorldResetRuntime";
    private static final Map<String, Set<String>> SUPPORTED_HASHES = Map.of(
            VEHICLES_DB, Set.of(
                    "f908628f3a94a018cc4666ef14bdb01326eeb90ca27f55d7b744d215a7a9f9ba"),
            ISO_CHUNK, Set.of(
                    "68431ace471b30c842ff7c2a6e706d8ba48d7a84ae07f876484153c0d62a794b"));

    private PZSelectiveWorldResetGuardAgent() {
    }

    public static void premain(String args, Instrumentation instrumentation) {
        try {
            instrumentation.addTransformer(new Transformer(), false);
            System.out.println("[PZSelectiveResetGuard] agent installed; unsupported classes remain vanilla");
        } catch (Throwable failure) {
            System.err.println("[PZSelectiveResetGuard] DISABLED setup failed; using vanilla reset behavior: "
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
            Set<String> hashes = SUPPORTED_HASHES.get(className);
            if (hashes == null) {
                return null;
            }
            String hash = sha256(classfileBuffer);
            if (!hashes.contains(hash)) {
                System.err.println("[PZSelectiveResetGuard] REFUSED " + className
                        + " unsupported SHA-256=" + hash + "; using vanilla class");
                return null;
            }
            try {
                ClassReader reader = new ClassReader(classfileBuffer);
                ClassWriter writer = new ClassWriter(reader, ClassWriter.COMPUTE_MAXS);
                HookVisitor visitor = new HookVisitor(writer, className);
                reader.accept(visitor, 0);
                if (!visitor.isComplete()) {
                    System.err.println("[PZSelectiveResetGuard] REFUSED " + className
                            + " unexpected method shape " + visitor.describe()
                            + "; using vanilla class");
                    return null;
                }
                System.out.println("[PZSelectiveResetGuard] ACTIVE " + className
                        + " SHA-256=" + hash);
                return writer.toByteArray();
            } catch (Throwable failure) {
                System.err.println("[PZSelectiveResetGuard] REFUSED " + className
                        + " transform failed=" + failure + "; using vanilla class");
                return null;
            }
        }
    }

    private static final class HookVisitor extends ClassVisitor {
        private final String className;
        private int targetMethods;
        private int hooks;

        private HookVisitor(ClassVisitor delegate, String className) {
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
            boolean vehiclesInit = VEHICLES_DB.equals(className)
                    && "init".equals(name)
                    && "()V".equals(descriptor);
            boolean chunkLoaded = ISO_CHUNK.equals(className)
                    && "doLoadGridsquare".equals(name)
                    && "()V".equals(descriptor);
            if (!vehiclesInit && !chunkLoaded) {
                return output;
            }
            targetMethods++;
            return new MethodVisitor(Opcodes.ASM9, output) {
                @Override
                public void visitInsn(int opcode) {
                    if (opcode == Opcodes.RETURN) {
                        if (vehiclesInit) {
                            super.visitMethodInsn(
                                    Opcodes.INVOKESTATIC,
                                    RUNTIME,
                                    "seedVehicleChunks",
                                    "()V",
                                    false);
                        } else {
                            super.visitVarInsn(Opcodes.ALOAD, 0);
                            super.visitMethodInsn(
                                    Opcodes.INVOKESTATIC,
                                    RUNTIME,
                                    "onChunkLoaded",
                                    "(Lzombie/iso/IsoChunk;)V",
                                    false);
                        }
                        hooks++;
                    }
                    super.visitInsn(opcode);
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
