package cn.zombiecommunity.pzdrying;

import java.io.InputStream;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

public final class TransformSmokeTest {
    private TransformSmokeTest() { }

    public static void main(String[] args) throws Exception {
        String resource = "/zombie/entity/components/crafting/CraftLogic.class";
        byte[] original;
        try (InputStream input = TransformSmokeTest.class.getResourceAsStream(resource)) {
            if (input == null) throw new IllegalStateException("Missing " + resource);
            original = input.readAllBytes();
        }
        byte[] transformed = DryingCraftSyncThrottleAgent.transformForTest(
                "zombie/entity/components/crafting/CraftLogic", original);
        if (transformed == null) throw new AssertionError("Expected supported class to transform");
        int[] calls = {0};
        new ClassReader(transformed).accept(new ClassVisitor(Opcodes.ASM9) {
            @Override
            public MethodVisitor visitMethod(int access, String name, String descriptor,
                    String signature, String[] exceptions) {
                return new MethodVisitor(Opcodes.ASM9) {
                    @Override
                    public void visitMethodInsn(int opcode, String owner, String method,
                            String calledDescriptor, boolean isInterface) {
                        if (opcode == Opcodes.INVOKESTATIC
                                && "cn/zombiecommunity/pzdrying/DryingCraftSyncThrottleRuntime".equals(owner)
                                && "allow".equals(method)) calls[0]++;
                    }
                };
            }
        }, 0);
        if (calls[0] != 1) throw new AssertionError("Expected one throttle hook, got " + calls[0]);
        byte[] changed = original.clone();
        changed[changed.length - 1] ^= 1;
        if (DryingCraftSyncThrottleAgent.transformForTest(
                "zombie/entity/components/crafting/CraftLogic", changed) != null) {
            throw new AssertionError("Unsupported class hash should be refused");
        }
        if (!DryingCraftSyncThrottleRuntime.allow(true, new Object())) {
            throw new AssertionError("Non-drying craft logic must remain unchanged");
        }
        System.out.println("PZDryingCraftSyncThrottle smoke test passed");
    }
}
