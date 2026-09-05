package cn.zombiecommunity.pzanimalLOS;

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

public final class AnimalLOSOptimizationAgent {
    private static final String ISO_ANIMAL = "zombie/characters/animals/IsoAnimal";
    private static final String ISO_CELL = "zombie/iso/IsoCell";
    private static final String RUNTIME =
            "cn/zombiecommunity/pzanimalLOS/AnimalLOSOptimizationRuntime";
    private static final String ISO_ANIMAL_HASH =
            "4bf06adfc24d9b4d2119c71ab0c1a46d7a2b56dded2cd2371bca867d71f22117";
    private static final AtomicBoolean INSTALLED = new AtomicBoolean();

    private AnimalLOSOptimizationAgent() { }

    public static void premain(String args, Instrumentation instrumentation) {
        install(args, instrumentation, false);
    }

    public static void agentmain(String args, Instrumentation instrumentation) {
        install(args, instrumentation, true);
    }

    private static void install(String args, Instrumentation instrumentation, boolean retransform) {
        if (!INSTALLED.compareAndSet(false, true)) {
            System.out.println("[PZAnimalLOS] already installed");
            return;
        }
        Config config = Config.parse(args);
        AnimalLOSOptimizationRuntime.start(config.enabled, config.reportSeconds);
        Transformer transformer = new Transformer();
        instrumentation.addTransformer(transformer, retransform);
        System.out.println("[PZAnimalLOS] agent installed enabled=" + config.enabled
                + " reportSeconds=" + config.reportSeconds);
        if (!retransform) return;

        Class<?> target = null;
        for (Class<?> loaded : instrumentation.getAllLoadedClasses()) {
            if (ISO_ANIMAL.equals(loaded.getName().replace('.', '/'))
                    && instrumentation.isModifiableClass(loaded)) {
                target = loaded;
                break;
            }
        }
        if (target == null) {
            System.out.println("[PZAnimalLOS] IsoAnimal not loaded; waiting for class load");
            return;
        }
        try {
            instrumentation.retransformClasses(target);
        } catch (Throwable failure) {
            instrumentation.removeTransformer(transformer);
            throw new IllegalStateException("IsoAnimal retransform failed", failure);
        }
        if (transformer.lastHookCount != 1) {
            instrumentation.removeTransformer(transformer);
            throw new IllegalStateException(
                    "Unexpected IsoAnimal hook count=" + transformer.lastHookCount);
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
            if (!ISO_ANIMAL.equals(className)) return null;
            String hash = sha256(bytes);
            if (!ISO_ANIMAL_HASH.equals(hash)) {
                System.err.println("[PZAnimalLOS] REFUSED unsupported " + className
                        + " SHA-256=" + hash + "; using vanilla class");
                return null;
            }
            try {
                int[] hooks = {0};
                ClassReader reader = new ClassReader(bytes);
                ClassWriter writer = new ClassWriter(reader, ClassWriter.COMPUTE_MAXS);
                reader.accept(new AnimalVisitor(writer, hooks), 0);
                lastHookCount = hooks[0];
                if (hooks[0] != 1) {
                    System.err.println("[PZAnimalLOS] REFUSED " + className
                            + " hookCount=" + hooks[0] + "; using vanilla class");
                    return null;
                }
                System.out.println("[PZAnimalLOS] ACTIVE " + className + " SHA-256=" + hash);
                return writer.toByteArray();
            } catch (Throwable failure) {
                System.err.println("[PZAnimalLOS] REFUSED transform " + className
                        + " failed=" + failure + "; using vanilla class");
                return null;
            }
        }
    }

    private static final class AnimalVisitor extends ClassVisitor {
        private final int[] hooks;

        AnimalVisitor(ClassVisitor output, int[] hooks) {
            super(Opcodes.ASM9, output);
            this.hooks = hooks;
        }

        @Override
        public MethodVisitor visitMethod(int access, String name, String descriptor,
                String signature, String[] exceptions) {
            MethodVisitor output = super.visitMethod(access, name, descriptor, signature, exceptions);
            if (!"updateLOS".equals(name) || !"()V".equals(descriptor)) return output;
            return new MethodVisitor(Opcodes.ASM9, output) {
                @Override
                public void visitMethodInsn(int opcode, String owner, String method,
                        String calledDescriptor, boolean isInterface) {
                    if (opcode == Opcodes.INVOKEVIRTUAL && ISO_CELL.equals(owner)
                            && "getObjectList".equals(method)
                            && "()Ljava/util/Set;".equals(calledDescriptor)) {
                        hooks[0]++;
                        super.visitVarInsn(Opcodes.ALOAD, 0);
                        super.visitMethodInsn(Opcodes.INVOKESTATIC, RUNTIME, "getCandidates",
                                "(Lzombie/iso/IsoCell;Lzombie/characters/animals/IsoAnimal;)"
                                        + "Ljava/util/Set;",
                                false);
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

    static record Config(boolean enabled, long reportSeconds) {
        static Config parse(String args) {
            boolean enabled = true;
            long reportSeconds = 60L;
            if (args != null && !args.isBlank()) {
                for (String token : args.split(",")) {
                    String[] pair = token.split("=", 2);
                    if (pair.length != 2) continue;
                    try {
                        switch (pair[0].trim()) {
                            case "enabled" -> enabled = Boolean.parseBoolean(pair[1].trim());
                            case "reportSeconds" -> reportSeconds =
                                    Math.max(30L, Math.min(86_400L,
                                            Long.parseLong(pair[1].trim())));
                            default -> { }
                        }
                    } catch (RuntimeException invalid) {
                        System.err.println("[PZAnimalLOS] ignored invalid option " + token);
                    }
                }
            }
            return new Config(enabled, reportSeconds);
        }
    }
}
