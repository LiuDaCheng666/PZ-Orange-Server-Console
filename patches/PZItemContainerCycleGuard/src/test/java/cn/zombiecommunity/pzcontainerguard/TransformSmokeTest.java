package cn.zombiecommunity.pzcontainerguard;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.jar.JarFile;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

public final class TransformSmokeTest {
    private static final String INTERNAL_NAME = "zombie/inventory/ItemContainer";
    private static final String BINARY_NAME = "zombie.inventory.ItemContainer";

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

        byte[] transformed = PZItemContainerCycleGuardAgent.transformForTest(INTERNAL_NAME, original);
        if (transformed == null || transformed.length == 0) {
            throw new AssertionError("ItemContainer was not transformed");
        }
        verifyMethodShape(transformed);
        verifyLoad(transformed);
        verifyHashRefusal(original);
        System.out.println("PZ item-container cycle guard transform smoke tests passed");
    }

    private static void verifyMethodShape(byte[] bytes) {
        AtomicInteger methods = new AtomicInteger();
        AtomicInteger recursiveCalls = new AtomicInteger();
        AtomicInteger reportCalls = new AtomicInteger();
        new ClassReader(bytes).accept(new ClassVisitor(Opcodes.ASM9) {
            @Override
            public MethodVisitor visitMethod(
                    int access,
                    String name,
                    String descriptor,
                    String signature,
                    String[] exceptions) {
                if (!"getCharacter".equals(name)
                        || !"()Lzombie/characters/IsoGameCharacter;".equals(descriptor)) {
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
                        if (INTERNAL_NAME.equals(owner) && "getCharacter".equals(methodName)) {
                            recursiveCalls.incrementAndGet();
                        }
                        if ("cn/zombiecommunity/pzcontainerguard/ItemContainerCycleGuardRuntime".equals(owner)
                                && "report".equals(methodName)) {
                            reportCalls.incrementAndGet();
                        }
                    }
                };
            }
        }, 0);

        if (methods.get() != 1) {
            throw new AssertionError("getCharacter method count=" + methods.get());
        }
        if (recursiveCalls.get() != 0) {
            throw new AssertionError("recursive getCharacter calls remain=" + recursiveCalls.get());
        }
        if (reportCalls.get() != 4) {
            throw new AssertionError("cycle report call sites expected=4 actual=" + reportCalls.get());
        }
    }

    private static void verifyLoad(byte[] transformed) throws Exception {
        ClassLoader parent = TransformSmokeTest.class.getClassLoader();
        ClassLoader loader = new ClassLoader(parent) {
            @Override
            protected Class<?> loadClass(String name, boolean resolve) throws ClassNotFoundException {
                if (!BINARY_NAME.equals(name)) {
                    return super.loadClass(name, resolve);
                }
                synchronized (getClassLoadingLock(name)) {
                    Class<?> loaded = findLoadedClass(name);
                    if (loaded == null) {
                        loaded = defineClass(name, transformed, 0, transformed.length);
                    }
                    if (resolve) {
                        resolveClass(loaded);
                    }
                    return loaded;
                }
            }
        };
        Class.forName(BINARY_NAME, false, loader);
    }

    private static void verifyHashRefusal(byte[] original) {
        byte[] changed = original.clone();
        changed[changed.length - 1] ^= 1;
        if (PZItemContainerCycleGuardAgent.transformForTest(INTERNAL_NAME, changed) != null) {
            throw new AssertionError("modified class hash should be refused");
        }
    }
}
