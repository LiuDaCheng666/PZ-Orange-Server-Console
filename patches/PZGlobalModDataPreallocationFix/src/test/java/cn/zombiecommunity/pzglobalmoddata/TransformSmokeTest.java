package cn.zombiecommunity.pzglobalmoddata;

import java.util.jar.JarFile;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

public final class TransformSmokeTest {
    private TransformSmokeTest() { }

    public static void main(String[] args) throws Exception {
        if (args.length != 1) throw new IllegalArgumentException("projectzomboid.jar path required");
        byte[] original;
        String resource = "zombie/world/moddata/GlobalModData.class";
        try (JarFile jar = new JarFile(args[0])) {
            original = jar.getInputStream(jar.getJarEntry(resource)).readAllBytes();
        }

        byte[] transformed = PZGlobalModDataPreallocationAgent.transformForTest(
                "zombie/world/moddata/GlobalModData", original);
        if (transformed == null) throw new AssertionError("GlobalModData transform refused");
        int[] runtimeCalls = {0};
        int[] vanillaAllocations = {0};
        new ClassReader(transformed).accept(new ClassVisitor(Opcodes.ASM9) {
            @Override
            public MethodVisitor visitMethod(int access, String name, String descriptor,
                    String signature, String[] exceptions) {
                if (!"save".equals(name) || !"()V".equals(descriptor)) return null;
                return new MethodVisitor(Opcodes.ASM9) {
                    @Override
                    public void visitMethodInsn(int opcode, String owner, String method,
                            String calledDescriptor, boolean isInterface) {
                        if (owner.equals("cn/zombiecommunity/pzglobalmoddata/"
                                + "GlobalModDataPreallocationRuntime")
                                && method.equals("allocate")) runtimeCalls[0]++;
                        if (owner.equals("java/nio/ByteBuffer") && method.equals("allocate")) {
                            vanillaAllocations[0]++;
                        }
                    }
                };
            }
        }, 0);
        if (runtimeCalls[0] != 1 || vanillaAllocations[0] != 0) {
            throw new AssertionError("Expected one runtime allocation hook, got runtime="
                    + runtimeCalls[0] + " vanilla=" + vanillaAllocations[0]);
        }

        byte[] unsupported = original.clone();
        unsupported[unsupported.length - 1] ^= 1;
        if (PZGlobalModDataPreallocationAgent.transformForTest(
                "zombie/world/moddata/GlobalModData", unsupported) != null) {
            throw new AssertionError("Unsupported GlobalModData must be refused");
        }
        if (PZGlobalModDataPreallocationAgent.transformForTest(
                "example/Other", original) != null) {
            throw new AssertionError("Unrelated class must be ignored");
        }
        System.out.println("PZ GlobalModData transform smoke test passed");
    }
}
