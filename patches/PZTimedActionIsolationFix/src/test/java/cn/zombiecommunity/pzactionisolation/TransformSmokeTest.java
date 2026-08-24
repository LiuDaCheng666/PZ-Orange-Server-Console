package cn.zombiecommunity.pzactionisolation;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.jar.JarFile;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

public final class TransformSmokeTest {
    private static final String TARGET = "zombie/core/ActionManager";

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

        byte[] transformed = PZTimedActionIsolationFixAgent.transformForTest(TARGET, original);
        if (transformed == null || transformed.length == 0) {
            throw new AssertionError("ActionManager was not transformed");
        }
        verifyHook(transformed);

        byte[] changed = original.clone();
        changed[changed.length - 1] ^= 1;
        if (PZTimedActionIsolationFixAgent.transformForTest(TARGET, changed) != null) {
            throw new AssertionError("modified class hash should be refused");
        }
        System.out.println("PZ timed-action isolation transform smoke tests passed");
    }

    private static void verifyHook(byte[] bytes) {
        AtomicInteger stopMethods = new AtomicInteger();
        AtomicInteger guardCalls = new AtomicInteger();
        AtomicInteger vanillaRemoveCalls = new AtomicInteger();
        new ClassReader(bytes).accept(new ClassVisitor(Opcodes.ASM9) {
            @Override
            public MethodVisitor visitMethod(
                    int access,
                    String name,
                    String descriptor,
                    String signature,
                    String[] exceptions) {
                if (!"stop".equals(name) || !"(Lzombie/core/Action;)V".equals(descriptor)) {
                    return null;
                }
                stopMethods.incrementAndGet();
                return new MethodVisitor(Opcodes.ASM9) {
                    @Override
                    public void visitMethodInsn(
                            int opcode,
                            String owner,
                            String methodName,
                            String methodDescriptor,
                            boolean isInterface) {
                        if ("cn/zombiecommunity/pzactionisolation/TimedActionIsolationRuntime".equals(owner)
                                && "stopExactOnServer".equals(methodName)) {
                            guardCalls.incrementAndGet();
                        }
                        if (TARGET.equals(owner)
                                && "remove".equals(methodName)
                                && "(BZ)V".equals(methodDescriptor)) {
                            vanillaRemoveCalls.incrementAndGet();
                        }
                    }
                };
            }
        }, 0);
        if (stopMethods.get() != 1 || guardCalls.get() != 1 || vanillaRemoveCalls.get() != 1) {
            throw new AssertionError("unexpected transformed shape stop=" + stopMethods.get()
                    + " guard=" + guardCalls.get() + " vanillaFallback=" + vanillaRemoveCalls.get());
        }
    }
}
