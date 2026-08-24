package cn.zombiecommunity.pzitempickfix;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.jar.JarFile;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

public final class TransformSmokeTest {
    private static final String TARGET = "zombie/inventory/ItemConfigurator";
    private static final String RUNTIME =
            "cn/zombiecommunity/pzitempickfix/ItemPickInfoContainerRuntime";

    private TransformSmokeTest() {
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 1 || !Files.isRegularFile(Path.of(args[0]))) {
            throw new IllegalArgumentException("game jar path is required");
        }
        byte[] original;
        try (JarFile jar = new JarFile(args[0])) {
            original = jar.getInputStream(jar.getJarEntry(TARGET + ".class")).readAllBytes();
        }

        byte[] transformed = PZItemPickInfoContainerFixAgent.transformForTest(TARGET, original);
        if (transformed == null || transformed.length == 0) {
            throw new AssertionError("ItemConfigurator was not transformed");
        }
        verifyHook(transformed);

        byte[] changed = original.clone();
        changed[changed.length - 1] ^= 1;
        if (PZItemPickInfoContainerFixAgent.transformForTest(TARGET, changed) != null) {
            throw new AssertionError("modified class hash should be refused");
        }
        System.out.println("PZ ItemPickInfo container transform smoke test passed");
    }

    private static void verifyHook(byte[] bytes) {
        AtomicInteger targetMethods = new AtomicInteger();
        AtomicInteger hooks = new AtomicInteger();
        AtomicInteger bucketCalls = new AtomicInteger();
        AtomicInteger hookSequence = new AtomicInteger(-1);
        AtomicInteger bucketSequence = new AtomicInteger(-1);
        AtomicInteger sequence = new AtomicInteger();
        new ClassReader(bytes).accept(new ClassVisitor(Opcodes.ASM9) {
            @Override
            public MethodVisitor visitMethod(
                    int access,
                    String name,
                    String descriptor,
                    String signature,
                    String[] exceptions) {
                if (!"Preprocess".equals(name) || !"()V".equals(descriptor)) {
                    return null;
                }
                targetMethods.incrementAndGet();
                return new MethodVisitor(Opcodes.ASM9) {
                    @Override
                    public void visitMethodInsn(
                            int opcode,
                            String owner,
                            String methodName,
                            String methodDescriptor,
                            boolean isInterface) {
                        int current = sequence.getAndIncrement();
                        if (RUNTIME.equals(owner)
                                && "registerMissingContainerIds".equals(methodName)) {
                            hooks.incrementAndGet();
                            hookSequence.set(current);
                        }
                        if ("zombie/scripting/ScriptManager".equals(owner)
                                && "getAllItemConfigs".equals(methodName)) {
                            bucketCalls.incrementAndGet();
                            bucketSequence.set(current);
                        }
                    }
                };
            }
        }, 0);
        if (targetMethods.get() != 1
                || hooks.get() != 1
                || bucketCalls.get() != 1
                || hookSequence.get() + 1 != bucketSequence.get()) {
            throw new AssertionError("unexpected transformed shape methods=" + targetMethods.get()
                    + " hooks=" + hooks.get() + " bucketCalls=" + bucketCalls.get()
                    + " hookSequence=" + hookSequence.get()
                    + " bucketSequence=" + bucketSequence.get());
        }
    }
}
