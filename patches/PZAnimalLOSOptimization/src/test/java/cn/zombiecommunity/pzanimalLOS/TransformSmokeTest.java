package cn.zombiecommunity.pzanimalLOS;

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
        String resource = "zombie/characters/animals/IsoAnimal.class";
        try (JarFile jar = new JarFile(args[0])) {
            original = jar.getInputStream(jar.getJarEntry(resource)).readAllBytes();
        }

        byte[] transformed = AnimalLOSOptimizationAgent.transformForTest(
                "zombie/characters/animals/IsoAnimal", original);
        if (transformed == null) throw new AssertionError("IsoAnimal transform refused");
        int[] runtimeCalls = {0};
        int[] vanillaCalls = {0};
        new ClassReader(transformed).accept(new ClassVisitor(Opcodes.ASM9) {
            @Override
            public MethodVisitor visitMethod(int access, String name, String descriptor,
                    String signature, String[] exceptions) {
                if (!"updateLOS".equals(name) || !"()V".equals(descriptor)) return null;
                return new MethodVisitor(Opcodes.ASM9) {
                    @Override
                    public void visitMethodInsn(int opcode, String owner, String method,
                            String calledDescriptor, boolean isInterface) {
                        if (owner.equals("cn/zombiecommunity/pzanimalLOS/"
                                + "AnimalLOSOptimizationRuntime")
                                && method.equals("getCandidates")) runtimeCalls[0]++;
                        if (owner.equals("zombie/iso/IsoCell")
                                && method.equals("getObjectList")) vanillaCalls[0]++;
                    }
                };
            }
        }, 0);
        if (runtimeCalls[0] != 1 || vanillaCalls[0] != 0) {
            throw new AssertionError("Expected one runtime call and no vanilla calls, got runtime="
                    + runtimeCalls[0] + " vanilla=" + vanillaCalls[0]);
        }

        byte[] transformedAgain = AnimalLOSOptimizationAgent.transformForTest(
                "zombie/characters/animals/IsoAnimal", original);
        if (transformedAgain == null) {
            throw new AssertionError("Repeated transform of original bytes must remain supported");
        }

        byte[] unsupported = original.clone();
        unsupported[unsupported.length - 1] ^= 1;
        if (AnimalLOSOptimizationAgent.transformForTest(
                "zombie/characters/animals/IsoAnimal", unsupported) != null) {
            throw new AssertionError("Unsupported IsoAnimal must be refused");
        }
        if (AnimalLOSOptimizationAgent.transformForTest("example/Other", original) != null) {
            throw new AssertionError("Unrelated class must be ignored");
        }
        AnimalLOSOptimizationAgent.Config maximum =
                AnimalLOSOptimizationAgent.Config.parse("reportSeconds=9223372036854776");
        if (maximum.reportSeconds() != 86_400L) {
            throw new AssertionError("reportSeconds upper bound was not applied");
        }
        AnimalLOSOptimizationAgent.Config invalid =
                AnimalLOSOptimizationAgent.Config.parse("reportSeconds=not-a-number");
        if (invalid.reportSeconds() != 60L) {
            throw new AssertionError("invalid reportSeconds must retain the default");
        }
        System.out.println("PZAnimalLOSOptimization transform smoke test passed");
    }
}
