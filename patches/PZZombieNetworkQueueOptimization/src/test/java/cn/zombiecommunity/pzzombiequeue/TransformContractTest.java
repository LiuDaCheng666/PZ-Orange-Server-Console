package cn.zombiecommunity.pzzombiequeue;

import java.util.jar.JarFile;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Label;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

public final class TransformContractTest {
    private static final String RESOURCE = "zombie/popman/NetworkZombiePacker.class";
    private static final String RUNTIME =
            "cn/zombiecommunity/pzzombiequeue/ZombieNetworkQueueRuntime";

    private TransformContractTest() { }

    public static void main(String[] args) throws Exception {
        if (args.length != 1) throw new IllegalArgumentException("projectzomboid.jar required");
        byte[] original;
        try (JarFile jar = new JarFile(args[0])) {
            original = jar.getInputStream(jar.getJarEntry(RESOURCE)).readAllBytes();
        }
        assertEquals(ZombieNetworkQueueAgent.TARGET_HASH,
                ZombieNetworkQueueAgent.sha256ForTest(original), "target class SHA-256");
        assertTrue(ZombieNetworkQueueAgent.matchesContractForTest(original),
                "audited postupdate contract must match");

        byte[] transformed = ZombieNetworkQueueAgent.transformForTest(
                ZombieNetworkQueueAgent.TARGET, original);
        assertTrue(transformed != null, "supported class must transform");
        Counts counts = countHooks(transformed);
        assertEquals(1, counts.containsAndReserve, "runtime contains hook count");
        assertEquals(1, counts.enter, "entry cleanup-scope hook count");
        assertEquals(2, counts.exit, "normal and exceptional cleanup hook count");
        assertEquals(0, counts.vanillaContains, "vanilla hotspot must be replaced");
        assertEquals(1, counts.vanillaAdd, "same-list add must remain vanilla");
        assertEquals(1, counts.throwableHandlers, "cleanup catch-all count");
        assertTrue(counts.cleanupHandlerIsLast,
                "cleanup catch-all must follow original monitor handlers");

        byte[] changed = original.clone();
        changed[changed.length - 1] ^= 1;
        assertTrue(ZombieNetworkQueueAgent.transformForTest(
                ZombieNetworkQueueAgent.TARGET, changed) == null,
                "hash mismatch must return original via null transform");
        assertTrue(ZombieNetworkQueueAgent.transformForTest("example/Other", original) == null,
                "unrelated class must be ignored");
        assertTrue(!ZombieNetworkQueueAgent.matchesContractForTest(
                mismatchedFixture(false)), "missing add must fail contract");
        assertTrue(!ZombieNetworkQueueAgent.matchesContractForTest(
                mismatchedFixture(true)), "different-list add must fail contract");

        testConfigBounds();
        System.out.println("TransformContractTest PASS");
    }

    private static Counts countHooks(byte[] bytes) {
        Counts counts = new Counts();
        new ClassReader(bytes).accept(new ClassVisitor(Opcodes.ASM9) {
            @Override
            public MethodVisitor visitMethod(int access, String name, String descriptor,
                    String signature, String[] exceptions) {
                if (!"postupdate".equals(name) || !"()V".equals(descriptor)) return null;
                return new MethodVisitor(Opcodes.ASM9) {
                    @Override
                    public void visitMethodInsn(int opcode, String owner, String method,
                            String calledDescriptor, boolean isInterface) {
                        if (RUNTIME.equals(owner) && "enter".equals(method)) counts.enter++;
                        if (RUNTIME.equals(owner) && "exit".equals(method)) counts.exit++;
                        if (RUNTIME.equals(owner) && "containsAndReserve".equals(method)) {
                            counts.containsAndReserve++;
                        }
                        if ("java/util/LinkedList".equals(owner)
                                && "contains".equals(method)) counts.vanillaContains++;
                        if ("java/util/LinkedList".equals(owner)
                                && "add".equals(method)) counts.vanillaAdd++;
                    }

                    @Override
                    public void visitTryCatchBlock(Label start, Label end, Label handler,
                            String type) {
                        counts.cleanupHandlerIsLast = "java/lang/Throwable".equals(type);
                        if ("java/lang/Throwable".equals(type)) counts.throwableHandlers++;
                    }
                };
            }
        }, 0);
        return counts;
    }

    private static byte[] mismatchedFixture(boolean differentListForAdd) {
        ClassWriter writer = new ClassWriter(ClassWriter.COMPUTE_MAXS);
        writer.visit(Opcodes.V17, Opcodes.ACC_PUBLIC,
                ZombieNetworkQueueAgent.TARGET, null, "java/lang/Object", null);
        MethodVisitor method = writer.visitMethod(
                Opcodes.ACC_PUBLIC, "postupdate", "()V", null, null);
        method.visitCode();
        method.visitVarInsn(Opcodes.ALOAD, 1);
        method.visitFieldInsn(Opcodes.GETFIELD,
                "zombie/popman/NetworkZombieList$NetworkZombie", "zombies",
                "Ljava/util/LinkedList;");
        method.visitVarInsn(Opcodes.ALOAD, 2);
        method.visitMethodInsn(Opcodes.INVOKEVIRTUAL, "java/util/LinkedList", "contains",
                "(Ljava/lang/Object;)Z", false);
        Label done = new Label();
        method.visitJumpInsn(Opcodes.IFNE, done);
        if (differentListForAdd) {
            method.visitVarInsn(Opcodes.ALOAD, 3);
            method.visitFieldInsn(Opcodes.GETFIELD,
                    "zombie/popman/NetworkZombieList$NetworkZombie", "zombies",
                    "Ljava/util/LinkedList;");
            method.visitVarInsn(Opcodes.ALOAD, 2);
            method.visitMethodInsn(Opcodes.INVOKEVIRTUAL, "java/util/LinkedList", "add",
                    "(Ljava/lang/Object;)Z", false);
            method.visitInsn(Opcodes.POP);
        }
        method.visitLabel(done);
        method.visitInsn(Opcodes.RETURN);
        method.visitMaxs(0, 0);
        method.visitEnd();
        writer.visitEnd();
        return writer.toByteArray();
    }

    private static void testConfigBounds() {
        ZombieNetworkQueueAgent.Config defaults = ZombieNetworkQueueAgent.Config.parse(null);
        assertEquals(64, defaults.threshold(), "default threshold");
        assertEquals(3, defaults.linearQueries(), "default linear queries");
        assertEquals(300L, defaults.reportSeconds(), "default report seconds");
        ZombieNetworkQueueAgent.Config bounded = ZombieNetworkQueueAgent.Config.parse(
                "threshold=-1,linearQueries=999999,reportSeconds=999999999999,enabled=false");
        assertEquals(64, bounded.threshold(), "minimum threshold");
        assertEquals(1_024, bounded.linearQueries(), "maximum linear queries");
        assertEquals(86_400L, bounded.reportSeconds(), "maximum report seconds");
        assertTrue(!bounded.enabled(), "enabled=false");
        ZombieNetworkQueueAgent.Config invalid = ZombieNetworkQueueAgent.Config.parse(
                "threshold=nope,linearQueries=nope,reportSeconds=nope,enabled=nope");
        assertEquals(64, invalid.threshold(), "invalid threshold retains default");
        assertEquals(3, invalid.linearQueries(), "invalid linear queries retains default");
        assertEquals(300L, invalid.reportSeconds(), "invalid report seconds retains default");
        assertTrue(invalid.enabled(), "invalid enabled retains default");
    }

    private static void assertTrue(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    private static void assertEquals(Object expected, Object actual, String message) {
        if (!expected.equals(actual)) {
            throw new AssertionError(message + ": expected=" + expected + " actual=" + actual);
        }
    }

    private static final class Counts {
        int enter;
        int exit;
        int containsAndReserve;
        int vanillaContains;
        int vanillaAdd;
        int throwableHandlers;
        boolean cleanupHandlerIsLast;
    }
}
