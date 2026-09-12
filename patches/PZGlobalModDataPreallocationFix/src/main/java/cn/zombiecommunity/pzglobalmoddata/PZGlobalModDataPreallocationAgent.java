package cn.zombiecommunity.pzglobalmoddata;

import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.security.MessageDigest;
import java.security.ProtectionDomain;
import java.util.HexFormat;
import java.util.concurrent.atomic.AtomicBoolean;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

public final class PZGlobalModDataPreallocationAgent {
    private static final String TARGET = "zombie/world/moddata/GlobalModData";
    private static final String RUNTIME =
            "cn/zombiecommunity/pzglobalmoddata/GlobalModDataPreallocationRuntime";
    private static final String TARGET_HASH =
            "61b27632d28a63f92667a727d40614f6ec1e22640a64a65a93508427bcf4d47d";
    private static final AtomicBoolean INSTALLED = new AtomicBoolean();

    private PZGlobalModDataPreallocationAgent() { }

    public static void premain(String args, Instrumentation instrumentation) {
        install(args, instrumentation, false);
    }

    public static void agentmain(String args, Instrumentation instrumentation) {
        install(args, instrumentation, true);
    }

    private static void install(String args, Instrumentation instrumentation, boolean retransform) {
        if (!INSTALLED.compareAndSet(false, true)) {
            System.out.println("[PZGlobalModDataPreallocation] already installed");
            return;
        }
        Config config = Config.parse(args);
        GlobalModDataPreallocationRuntime.configure(
                config.enabled, config.headroomBytes, config.maxPreallocateBytes);
        Transformer transformer = new Transformer();
        instrumentation.addTransformer(transformer, retransform);
        System.out.println("[PZGlobalModDataPreallocation] agent installed enabled=" + config.enabled
                + " headroomBytes=" + config.headroomBytes
                + " maxPreallocateBytes=" + config.maxPreallocateBytes);
        if (!retransform) return;

        Class<?> target = null;
        for (Class<?> loaded : instrumentation.getAllLoadedClasses()) {
            if (TARGET.equals(loaded.getName().replace('.', '/'))
                    && instrumentation.isModifiableClass(loaded)) {
                target = loaded;
                break;
            }
        }
        if (target == null) {
            System.out.println("[PZGlobalModDataPreallocation] GlobalModData not loaded; waiting for class load");
            return;
        }
        try {
            instrumentation.retransformClasses(target);
        } catch (Throwable failure) {
            instrumentation.removeTransformer(transformer);
            throw new IllegalStateException("GlobalModData retransform failed", failure);
        }
        if (transformer.lastHookCount != 1) {
            instrumentation.removeTransformer(transformer);
            throw new IllegalStateException(
                    "Unexpected GlobalModData.save hook count=" + transformer.lastHookCount);
        }
    }

    static byte[] transformForTest(String className, byte[] bytes) {
        return new Transformer().transform(null, className, null, null, bytes);
    }

    private static final class Transformer implements ClassFileTransformer {
        volatile int lastHookCount;

        @Override
        public byte[] transform(ClassLoader loader, String className, Class<?> classBeingRedefined,
                ProtectionDomain protectionDomain, byte[] bytes) {
            if (!TARGET.equals(className)) return null;
            String hash = sha256(bytes);
            if (!TARGET_HASH.equals(hash)) {
                System.err.println("[PZGlobalModDataPreallocation] REFUSED unsupported " + className
                        + " SHA-256=" + hash + "; using vanilla class");
                return null;
            }
            try {
                int[] hooks = {0};
                ClassReader reader = new ClassReader(bytes);
                ClassWriter writer = new ClassWriter(reader, ClassWriter.COMPUTE_MAXS);
                reader.accept(new GlobalModDataVisitor(writer, hooks), 0);
                lastHookCount = hooks[0];
                if (hooks[0] != 1) {
                    System.err.println("[PZGlobalModDataPreallocation] REFUSED " + className
                            + " saveHookCount=" + hooks[0] + "; using vanilla class");
                    return null;
                }
                System.out.println("[PZGlobalModDataPreallocation] ACTIVE " + className
                        + " SHA-256=" + hash);
                return writer.toByteArray();
            } catch (Throwable failure) {
                System.err.println("[PZGlobalModDataPreallocation] REFUSED transform " + className
                        + " failed=" + failure + "; using vanilla class");
                return null;
            }
        }
    }

    private static final class GlobalModDataVisitor extends ClassVisitor {
        private final int[] hooks;

        GlobalModDataVisitor(ClassVisitor output, int[] hooks) {
            super(Opcodes.ASM9, output);
            this.hooks = hooks;
        }

        @Override
        public MethodVisitor visitMethod(int access, String name, String descriptor,
                String signature, String[] exceptions) {
            MethodVisitor output = super.visitMethod(access, name, descriptor, signature, exceptions);
            if (!"save".equals(name) || !"()V".equals(descriptor)) return output;
            return new MethodVisitor(Opcodes.ASM9, output) {
                @Override
                public void visitMethodInsn(int opcode, String owner, String method,
                        String calledDescriptor, boolean isInterface) {
                    if (opcode == Opcodes.INVOKESTATIC && "java/nio/ByteBuffer".equals(owner)
                            && "allocate".equals(method)
                            && "(I)Ljava/nio/ByteBuffer;".equals(calledDescriptor)) {
                        hooks[0]++;
                        super.visitMethodInsn(Opcodes.INVOKESTATIC, RUNTIME, "allocate",
                                "(I)Ljava/nio/ByteBuffer;", false);
                        return;
                    }
                    super.visitMethodInsn(opcode, owner, method, calledDescriptor, isInterface);
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

    static record Config(boolean enabled, int headroomBytes, int maxPreallocateBytes) {
        static Config parse(String args) {
            boolean enabled = true;
            int headroomBytes = 4 * 1024 * 1024;
            int maxPreallocateBytes = 256 * 1024 * 1024;
            if (args != null && !args.isBlank()) {
                for (String token : args.split(",")) {
                    String[] pair = token.split("=", 2);
                    if (pair.length != 2) continue;
                    try {
                        switch (pair[0].trim()) {
                            case "enabled" -> enabled = Boolean.parseBoolean(pair[1].trim());
                            case "headroomBytes" -> headroomBytes = Math.max(0,
                                    Math.min(64 * 1024 * 1024, Integer.parseInt(pair[1].trim())));
                            case "maxPreallocateBytes" -> maxPreallocateBytes = Math.max(
                                    16 * 1024 * 1024,
                                    Math.min(1024 * 1024 * 1024, Integer.parseInt(pair[1].trim())));
                            default -> { }
                        }
                    } catch (RuntimeException invalid) {
                        System.err.println("[PZGlobalModDataPreallocation] ignored invalid option " + token);
                    }
                }
            }
            return new Config(enabled, headroomBytes, maxPreallocateBytes);
        }
    }
}
