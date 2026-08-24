package cn.zombiecommunity.pzspritealias;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.jar.JarFile;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

public final class TransformSmokeTest {
    private static final String OBJECT_INFO =
            "zombie/entity/components/spriteconfig/SpriteConfigManager$ObjectInfo";
    private static final String FACE_INFO =
            "zombie/entity/components/spriteconfig/SpriteConfigManager$FaceInfo";
    private static final String TILE_INFO =
            "zombie/entity/components/spriteconfig/SpriteConfigManager$TileInfo";
    private static final String RUNTIME =
            "cn/zombiecommunity/pzspritealias/SpriteAliasRuntime";

    private TransformSmokeTest() {
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 1 || !Files.isRegularFile(Path.of(args[0]))) {
            throw new IllegalArgumentException("game jar path is required");
        }
        try (JarFile jar = new JarFile(args[0])) {
            verifyTransform(jar, OBJECT_INFO, "getFaceForSprite", "normalize");
            verifyTransform(jar, FACE_INFO, "getTileInfoForSprite", "normalize");
            verifyTransform(jar, TILE_INFO, "verifyObject", "spritesEquivalent");
        }
        verifyAliases();
        System.out.println("PZ SpriteConfig alias transform and runtime tests passed");
    }

    private static void verifyTransform(
            JarFile jar, String className, String methodName, String runtimeMethod) throws Exception {
        byte[] original = jar.getInputStream(jar.getJarEntry(className + ".class")).readAllBytes();
        byte[] transformed = PZSpriteConfigAliasAgent.transformForTest(className, original);
        if (transformed == null || transformed.length == 0) {
            throw new AssertionError(className + " was not transformed");
        }
        AtomicInteger calls = new AtomicInteger();
        new ClassReader(transformed).accept(new ClassVisitor(Opcodes.ASM9) {
            @Override
            public MethodVisitor visitMethod(
                    int access,
                    String name,
                    String descriptor,
                    String signature,
                    String[] exceptions) {
                if (!methodName.equals(name)) {
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
                                && runtimeMethod.equals(name)) {
                            calls.incrementAndGet();
                        }
                    }
                };
            }
        }, 0);
        if (calls.get() != 1) {
            throw new AssertionError(className + " unexpected runtime calls=" + calls.get());
        }

        byte[] changed = original.clone();
        changed[changed.length - 1] ^= 1;
        if (PZSpriteConfigAliasAgent.transformForTest(className, changed) != null) {
            throw new AssertionError(className + " modified hash should be refused");
        }
    }

    private static void verifyAliases() {
        Map<String, String> expected = Map.of(
                "ct_oac_fixtures_counters_01_33", "fixtures_counters_01_33",
                "ct_oac_furniture_storage_02_11", "furniture_storage_02_11",
                "ct_oac_carpentry_02_10", "carpentry_02_10",
                "fixtures_windows_01_6", "fixtures_windows_01_0",
                "fixtures_windows_01_7", "fixtures_windows_01_1",
                "LS_Inventions_10", "LS_Inventions_4");
        for (Map.Entry<String, String> entry : expected.entrySet()) {
            if (!entry.getValue().equals(SpriteAliasRuntime.normalize(entry.getKey()))) {
                throw new AssertionError("missing alias " + entry);
            }
            if (!SpriteAliasRuntime.spritesEquivalent(entry.getKey(), entry.getValue())) {
                throw new AssertionError("equivalence failed " + entry);
            }
        }
        String untouched = "fixtures_windows_01_8";
        if (!untouched.equals(SpriteAliasRuntime.normalize(untouched))) {
            throw new AssertionError("unexpected broad aliasing for " + untouched);
        }
    }
}
