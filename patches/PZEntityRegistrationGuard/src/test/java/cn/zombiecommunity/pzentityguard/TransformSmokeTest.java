package cn.zombiecommunity.pzentityguard;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.jar.JarFile;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

public final class TransformSmokeTest {
    private static final String INTERNAL_NAME = "zombie/entity/EngineEntityManager";

    private TransformSmokeTest() {
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 1 || !Files.isRegularFile(Path.of(args[0]))) {
            throw new IllegalArgumentException("game jar path is required");
        }
        byte[] original;
        try (JarFile jar = new JarFile(args[0])) {
            original = jar.getInputStream(jar.getJarEntry(INTERNAL_NAME + ".class")).readAllBytes();
        }

        byte[] transformed = PZEntityRegistrationGuardAgent.transformForTest(INTERNAL_NAME, original);
        if (transformed == null || transformed.length == 0) {
            throw new AssertionError("EngineEntityManager was not transformed");
        }
        verifyMethodShape(transformed);
        verifyHashRefusal(original);
        System.out.println("PZ entity-registration guard transform smoke tests passed");
    }

    private static void verifyMethodShape(byte[] bytes) {
        AtomicInteger methods = new AtomicInteger();
        AtomicInteger reports = new AtomicInteger();
        AtomicInteger containsCalls = new AtomicInteger();
        AtomicInteger returns = new AtomicInteger();
        new ClassReader(bytes).accept(new ClassVisitor(Opcodes.ASM9) {
            @Override
            public MethodVisitor visitMethod(
                    int access,
                    String name,
                    String descriptor,
                    String signature,
                    String[] exceptions) {
                if (!"addEntityInternal".equals(name)
                        || !"(Lzombie/entity/GameEntity;)V".equals(descriptor)) {
                    return null;
                }
                methods.incrementAndGet();
                return new MethodVisitor(Opcodes.ASM9) {
                    @Override
                    public void visitMethodInsn(
                            int opcode,
                            String owner,
                            String methodName,
                            String methodDescriptor,
                            boolean isInterface) {
                        if ("zombie/entity/util/ObjectSet".equals(owner)
                                && "contains".equals(methodName)) {
                            containsCalls.incrementAndGet();
                        }
                        if ("cn/zombiecommunity/pzentityguard/EntityRegistrationGuardRuntime".equals(owner)
                                && "reportSuppressedDuplicate".equals(methodName)) {
                            reports.incrementAndGet();
                        }
                    }

                    @Override
                    public void visitInsn(int opcode) {
                        if (opcode == Opcodes.RETURN) {
                            returns.incrementAndGet();
                        }
                    }
                };
            }
        }, 0);

        if (methods.get() != 1 || reports.get() != 1 || containsCalls.get() != 2 || returns.get() != 2) {
            throw new AssertionError("unexpected method shape methods=" + methods
                    + " reports=" + reports + " contains=" + containsCalls + " returns=" + returns);
        }
    }

    private static void verifyHashRefusal(byte[] original) {
        byte[] changed = original.clone();
        changed[changed.length - 1] ^= 1;
        if (PZEntityRegistrationGuardAgent.transformForTest(INTERNAL_NAME, changed) != null) {
            throw new AssertionError("modified class hash should be refused");
        }
    }
}
