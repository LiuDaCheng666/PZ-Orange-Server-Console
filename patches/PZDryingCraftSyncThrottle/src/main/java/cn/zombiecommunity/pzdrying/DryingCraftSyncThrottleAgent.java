package cn.zombiecommunity.pzdrying;

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
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

public final class DryingCraftSyncThrottleAgent {
    private static final String TARGET = "zombie/entity/components/crafting/CraftLogic";
    private static final String UPDATE_DESCRIPTOR =
            "(Lzombie/entity/components/crafting/recipe/CraftRecipeData;)V";
    private static final String RUNTIME =
            "cn/zombiecommunity/pzdrying/DryingCraftSyncThrottleRuntime";
    private static final Set<String> SUPPORTED_HASHES = Set.of(
            "3d8ffd3163cbb9597f01b6d81cb610d6155a7b583c7ef161e2f11af1667ec68d");
    private static final AtomicBoolean INSTALLED = new AtomicBoolean();

    private DryingCraftSyncThrottleAgent() { }

    public static void premain(String args, Instrumentation instrumentation) {
        install(args, instrumentation, false);
    }

    public static void agentmain(String args, Instrumentation instrumentation) throws Exception {
        install(args, instrumentation, true);
    }

    private static void install(String args, Instrumentation instrumentation, boolean retransform) {
        if (!INSTALLED.compareAndSet(false, true)) {
            System.out.println("[PZDryingSyncThrottle] already installed");
            return;
        }
        Config config = Config.parse(args);
        DryingCraftSyncThrottleRuntime.start(config.intervalMs, config.reportSeconds);
        Transformer transformer = new Transformer();
        instrumentation.addTransformer(transformer, retransform);
        System.out.println("[PZDryingSyncThrottle] agent installed intervalMs=" + config.intervalMs
                + " reportSeconds=" + config.reportSeconds);
        if (!retransform) return;
        Class<?> target = findTarget(instrumentation);
        if (target == null || !instrumentation.isModifiableClass(target)) {
            throw new IllegalStateException("CraftLogic is unavailable or not modifiable");
        }
        try {
            instrumentation.retransformClasses(target);
        } catch (Throwable failure) {
            instrumentation.removeTransformer(transformer);
            throw new IllegalStateException("CraftLogic retransform failed", failure);
        }
        if (transformer.hooks != 1) {
            instrumentation.removeTransformer(transformer);
            throw new IllegalStateException("Unexpected hook count " + transformer.hooks);
        }
    }

    private static Class<?> findTarget(Instrumentation instrumentation) {
        for (Class<?> loaded : instrumentation.getAllLoadedClasses()) {
            if (loaded.getName().equals(TARGET.replace('/', '.'))) return loaded;
        }
        return null;
    }

    static byte[] transformForTest(String className, byte[] bytes) {
        return new Transformer().transform(null, className, null, null, bytes);
    }

    private static final class Transformer implements ClassFileTransformer {
        volatile int hooks;

        @Override
        public byte[] transform(ClassLoader loader, String className, Class<?> classBeingRedefined,
                ProtectionDomain protectionDomain, byte[] bytes) {
            if (!TARGET.equals(className)) return null;
            String hash = sha256(bytes);
            if (!SUPPORTED_HASHES.contains(hash)) {
                System.err.println("[PZDryingSyncThrottle] REFUSED unsupported CraftLogic.class SHA-256="
                        + hash + "; using vanilla class");
                return null;
            }
            try {
                ClassReader reader = new ClassReader(bytes);
                ClassWriter writer = new ClassWriter(reader, ClassWriter.COMPUTE_MAXS);
                reader.accept(new ClassVisitor(Opcodes.ASM9, writer) {
                    @Override
                    public MethodVisitor visitMethod(int access, String name, String descriptor,
                            String signature, String[] exceptions) {
                        MethodVisitor output = super.visitMethod(
                                access, name, descriptor, signature, exceptions);
                        if (!"onUpdate".equals(name) || !UPDATE_DESCRIPTOR.equals(descriptor)) {
                            return output;
                        }
                        return new MethodVisitor(Opcodes.ASM9, output) {
                            @Override
                            public void visitMethodInsn(int opcode, String owner, String method,
                                    String calledDescriptor, boolean isInterface) {
                                super.visitMethodInsn(opcode, owner, method, calledDescriptor, isInterface);
                                if (opcode == Opcodes.INVOKEVIRTUAL
                                        && "zombie/core/utils/UpdateLimit".equals(owner)
                                        && "Check".equals(method) && "()Z".equals(calledDescriptor)) {
                                    hooks++;
                                    super.visitVarInsn(Opcodes.ALOAD, 0);
                                    super.visitMethodInsn(Opcodes.INVOKESTATIC, RUNTIME, "allow",
                                            "(ZLjava/lang/Object;)Z", false);
                                }
                            }
                        };
                    }
                }, 0);
                if (hooks != 1) {
                    System.err.println("[PZDryingSyncThrottle] REFUSED onUpdate hook count=" + hooks
                            + "; using vanilla class");
                    return null;
                }
                System.out.println("[PZDryingSyncThrottle] ACTIVE CraftLogic.onUpdate SHA-256=" + hash);
                return writer.toByteArray();
            } catch (Throwable failure) {
                System.err.println("[PZDryingSyncThrottle] REFUSED transform failed=" + failure
                        + "; using vanilla class");
                return null;
            }
        }
    }

    private static String sha256(byte[] bytes) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));
        } catch (Exception failure) {
            throw new IllegalStateException("SHA-256 unavailable", failure);
        }
    }

    private record Config(long intervalMs, long reportSeconds) {
        static Config parse(String args) {
            long intervalMs = 10_000L;
            long reportSeconds = 300L;
            if (args != null && !args.isBlank()) {
                for (String token : args.split(",")) {
                    String[] pair = token.split("=", 2);
                    if (pair.length != 2) continue;
                    switch (pair[0].trim()) {
                        case "intervalMs" -> intervalMs = Math.max(1000L, Long.parseLong(pair[1].trim()));
                        case "reportSeconds" -> reportSeconds = Math.max(30L, Long.parseLong(pair[1].trim()));
                        default -> { }
                    }
                }
            }
            return new Config(intervalMs, reportSeconds);
        }
    }
}
