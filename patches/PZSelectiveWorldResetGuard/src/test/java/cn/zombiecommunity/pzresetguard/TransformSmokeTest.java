package cn.zombiecommunity.pzresetguard;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.jar.JarFile;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

public final class TransformSmokeTest {
    private static final String RUNTIME =
            "cn/zombiecommunity/pzresetguard/SelectiveWorldResetRuntime";

    private TransformSmokeTest() {
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 1 || !Files.isRegularFile(Path.of(args[0]))) {
            throw new IllegalArgumentException("game jar path is required");
        }
        try (JarFile jar = new JarFile(args[0])) {
            verifyTarget(
                    jar,
                    "zombie/vehicles/VehiclesDB2",
                    "init",
                    "seedVehicleChunks",
                    "()V");
            verifyTarget(
                    jar,
                    "zombie/iso/IsoChunk",
                    "doLoadGridsquare",
                    "onChunkLoaded",
                    "(Lzombie/iso/IsoChunk;)V");
        }
        System.out.println("PZ selective world reset guard transform smoke test passed");
    }

    private static void verifyTarget(
            JarFile jar,
            String className,
            String methodName,
            String hookName,
            String hookDescriptor) throws Exception {
        byte[] original = jar.getInputStream(jar.getJarEntry(className + ".class")).readAllBytes();
        byte[] transformed = PZSelectiveWorldResetGuardAgent.transformForTest(className, original);
        if (transformed == null || transformed.length == 0) {
            throw new AssertionError(className + " was not transformed");
        }
        AtomicInteger hooks = new AtomicInteger();
        new ClassReader(transformed).accept(new ClassVisitor(Opcodes.ASM9) {
            @Override
            public MethodVisitor visitMethod(
                    int access,
                    String name,
                    String descriptor,
                    String signature,
                    String[] exceptions) {
                if (!methodName.equals(name) || !"()V".equals(descriptor)) {
                    return null;
                }
                return new MethodVisitor(Opcodes.ASM9) {
                    @Override
                    public void visitMethodInsn(
                            int opcode,
                            String owner,
                            String name,
                            String descriptor,
                            boolean isInterface) {
                        if (opcode == Opcodes.INVOKESTATIC
                                && RUNTIME.equals(owner)
                                && hookName.equals(name)
                                && hookDescriptor.equals(descriptor)) {
                            hooks.incrementAndGet();
                        }
                    }
                };
            }
        }, 0);
        if (hooks.get() != 1) {
            throw new AssertionError(className + " hook count=" + hooks.get());
        }

        byte[] changed = original.clone();
        changed[changed.length - 1] ^= 1;
        if (PZSelectiveWorldResetGuardAgent.transformForTest(className, changed) != null) {
            throw new AssertionError(className + " modified hash should be refused");
        }
    }
}
