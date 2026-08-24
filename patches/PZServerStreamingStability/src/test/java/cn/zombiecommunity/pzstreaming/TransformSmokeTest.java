package cn.zombiecommunity.pzstreaming;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.jar.JarFile;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

public final class TransformSmokeTest {
    private TransformSmokeTest() {
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 1 || !Files.isRegularFile(Path.of(args[0]))) {
            throw new IllegalArgumentException("game jar path is required");
        }
        try (JarFile jar = new JarFile(args[0])) {
            checkObjectPacket(jar);
            checkServerMap(jar);
        }
        System.out.println("PZ streaming stability transform smoke tests passed");
    }

    private static void checkObjectPacket(JarFile jar) throws Exception {
        String name = "zombie/network/packets/ObjectModDataPacket";
        byte[] original = jar.getInputStream(jar.getJarEntry(name + ".class")).readAllBytes();
        byte[] transformed = PZServerStreamingStabilityAgent.transformForTest(name, original);
        if (transformed == null || transformed.length <= original.length) {
            throw new AssertionError("ObjectModDataPacket was not transformed");
        }
        Map<String, AtomicInteger> hooks = countRuntimeHooks(transformed);
        expect(hooks, "begin", 1);
        expect(hooks, "handleUnresolved", 1);
        expect(hooks, "isHandled", 1);
        expect(hooks, "consumeHandled", 1);
        verifyLoad("zombie.network.packets.ObjectModDataPacket", transformed);
        verifyHashRefusal(name, original);
    }

    private static void checkServerMap(JarFile jar) throws Exception {
        String name = "zombie/network/ServerMap";
        byte[] original = jar.getInputStream(jar.getJarEntry(name + ".class")).readAllBytes();
        byte[] transformed = PZServerStreamingStabilityAgent.transformForTest(name, original);
        if (transformed == null || transformed.length <= original.length) {
            throw new AssertionError("ServerMap was not transformed");
        }
        expect(countRuntimeHooks(transformed), "drain", 1);
        verifyLoad("zombie.network.ServerMap", transformed);
        verifyHashRefusal(name, original);
    }

    private static void verifyLoad(String binaryName, byte[] transformed) throws Exception {
        ClassLoader parent = TransformSmokeTest.class.getClassLoader();
        ClassLoader loader = new ClassLoader(parent) {
            @Override
            protected Class<?> loadClass(String name, boolean resolve) throws ClassNotFoundException {
                if (!binaryName.equals(name)) {
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
        Class.forName(binaryName, false, loader);
    }

    private static void verifyHashRefusal(String name, byte[] original) {
        byte[] changed = original.clone();
        changed[changed.length - 1] ^= 1;
        if (PZServerStreamingStabilityAgent.transformForTest(name, changed) != null) {
            throw new AssertionError("modified class hash should be refused for " + name);
        }
    }

    private static Map<String, AtomicInteger> countRuntimeHooks(byte[] bytes) {
        Map<String, AtomicInteger> counts = new HashMap<>();
        new ClassReader(bytes).accept(new ClassVisitor(Opcodes.ASM9) {
            @Override
            public MethodVisitor visitMethod(
                    int access,
                    String name,
                    String descriptor,
                    String signature,
                    String[] exceptions) {
                return new MethodVisitor(Opcodes.ASM9) {
                    @Override
                    public void visitMethodInsn(
                            int opcode,
                            String owner,
                            String methodName,
                            String methodDescriptor,
                            boolean isInterface) {
                        if ("cn/zombiecommunity/pzstreaming/ObjectModDataRuntime".equals(owner)) {
                            counts.computeIfAbsent(methodName, ignored -> new AtomicInteger()).incrementAndGet();
                        }
                    }
                };
            }
        }, 0);
        return counts;
    }

    private static void expect(Map<String, AtomicInteger> counts, String name, int expected) {
        int actual = counts.getOrDefault(name, new AtomicInteger()).get();
        if (actual != expected) {
            throw new AssertionError(name + " hook count expected=" + expected + " actual=" + actual);
        }
    }
}
