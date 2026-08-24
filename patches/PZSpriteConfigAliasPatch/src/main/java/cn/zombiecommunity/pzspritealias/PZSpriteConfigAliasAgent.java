package cn.zombiecommunity.pzspritealias;

import java.io.InputStream;
import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.security.MessageDigest;
import java.security.ProtectionDomain;
import java.util.HexFormat;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicBoolean;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

public final class PZSpriteConfigAliasAgent {
    private static final String OBJECT_INFO =
            "zombie/entity/components/spriteconfig/SpriteConfigManager$ObjectInfo";
    private static final String FACE_INFO =
            "zombie/entity/components/spriteconfig/SpriteConfigManager$FaceInfo";
    private static final String TILE_INFO =
            "zombie/entity/components/spriteconfig/SpriteConfigManager$TileInfo";
    private static final String RUNTIME =
            "cn/zombiecommunity/pzspritealias/SpriteAliasRuntime";
    private static final Map<String, Set<String>> SUPPORTED_HASHES = Map.of(
            OBJECT_INFO, Set.of("4d23c4854a86c594360a0934ce574349afbf7c045ee044c7d08092ba5c9ba358"),
            FACE_INFO, Set.of("f6e8e359d1c2013bc7f4f56e816984584ec4dac7b7ab7d0eec307b818b1c17d0"),
            TILE_INFO, Set.of("8de8de3cd3defce5be43a82ef4916664b4350ade05736a6d1a149de39d230871"));
    private static final AtomicBoolean INSTALLED = new AtomicBoolean();
    private static final Set<String> ACTIVATED = ConcurrentHashMap.newKeySet();

    private PZSpriteConfigAliasAgent() {
    }

    public static void premain(String args, Instrumentation instrumentation) {
        if (!INSTALLED.compareAndSet(false, true)) {
            System.out.println("[PZSpriteAlias] already installed");
            return;
        }
        if (!isEnabled(args)) {
            System.out.println("[PZSpriteAlias] disabled by configuration");
            return;
        }
        if (!validateSupportedTargets()) {
            System.err.println("[PZSpriteAlias] REFUSED target validation failed; all classes remain vanilla");
            return;
        }
        instrumentation.addTransformer(new Transformer(), false);
        System.out.println("[PZSpriteAlias] agent installed aliases=" + SpriteAliasRuntime.aliasCount());
    }

    static byte[] transformForTest(String className, byte[] classfileBuffer) {
        return new Transformer().transform(null, className, null, null, classfileBuffer);
    }

    static boolean wasActivated(String className) {
        return ACTIVATED.contains(className);
    }

    private static boolean isEnabled(String args) {
        if (args == null || args.isBlank()) {
            return true;
        }
        for (String entry : args.split(",")) {
            String[] pair = entry.trim().split("=", 2);
            if (pair.length == 2 && "enabled".equalsIgnoreCase(pair[0].trim())) {
                return Boolean.parseBoolean(pair[1].trim());
            }
        }
        return true;
    }

    private static boolean validateSupportedTargets() {
        for (Map.Entry<String, Set<String>> target : SUPPORTED_HASHES.entrySet()) {
            String resourceName = target.getKey() + ".class";
            try (InputStream input = ClassLoader.getSystemResourceAsStream(resourceName)) {
                if (input == null) {
                    System.err.println("[PZSpriteAlias] REFUSED missing target " + resourceName);
                    return false;
                }
                String hash = sha256(input.readAllBytes());
                if (!target.getValue().contains(hash)) {
                    System.err.println("[PZSpriteAlias] REFUSED unsupported target "
                            + target.getKey() + " SHA-256=" + hash);
                    return false;
                }
            } catch (Exception failure) {
                System.err.println("[PZSpriteAlias] REFUSED validation failure "
                        + resourceName + " error=" + failure);
                return false;
            }
        }
        return true;
    }

    private static final class Transformer implements ClassFileTransformer {
        @Override
        public byte[] transform(
                ClassLoader loader,
                String className,
                Class<?> classBeingRedefined,
                ProtectionDomain protectionDomain,
                byte[] classfileBuffer) {
            Set<String> hashes = SUPPORTED_HASHES.get(className);
            if (hashes == null) {
                return null;
            }
            String hash = sha256(classfileBuffer);
            if (!hashes.contains(hash)) {
                System.err.println("[PZSpriteAlias] REFUSED unsupported "
                        + className + " SHA-256=" + hash + "; using vanilla class");
                return null;
            }

            try {
                ClassReader reader = new ClassReader(classfileBuffer);
                ClassWriter writer = new ClassWriter(
                        reader, ClassWriter.COMPUTE_FRAMES | ClassWriter.COMPUTE_MAXS);
                PatchVisitor visitor = new PatchVisitor(writer, className);
                reader.accept(visitor, ClassReader.SKIP_FRAMES);
                if (!visitor.isComplete()) {
                    System.err.println("[PZSpriteAlias] REFUSED incomplete patch for "
                            + className + " details=" + visitor.describe());
                    return null;
                }
                ACTIVATED.add(className);
                System.out.println("[PZSpriteAlias] ACTIVE " + className + " SHA-256=" + hash);
                return writer.toByteArray();
            } catch (Throwable failure) {
                System.err.println("[PZSpriteAlias] REFUSED transform failed for "
                        + className + " error=" + failure + "; using vanilla class");
                return null;
            }
        }
    }

    private static final class PatchVisitor extends ClassVisitor {
        private final String className;
        private int targetMethods;
        private int replacements;

        private PatchVisitor(ClassVisitor delegate, String className) {
            super(Opcodes.ASM9, delegate);
            this.className = className;
        }

        @Override
        public MethodVisitor visitMethod(
                int access,
                String name,
                String descriptor,
                String signature,
                String[] exceptions) {
            MethodVisitor output = super.visitMethod(
                    access, name, descriptor, signature, exceptions);
            if (OBJECT_INFO.equals(className)
                    && "getFaceForSprite".equals(name)
                    && descriptor.startsWith("(Ljava/lang/String;)")) {
                targetMethods++;
                return normalizeArgumentAtEntry(output);
            }
            if (FACE_INFO.equals(className)
                    && "getTileInfoForSprite".equals(name)
                    && descriptor.startsWith("(Ljava/lang/String;)")) {
                targetMethods++;
                return normalizeArgumentAtEntry(output);
            }
            if (TILE_INFO.equals(className)
                    && "verifyObject".equals(name)
                    && "(Lzombie/iso/IsoObject;)Z".equals(descriptor)) {
                targetMethods++;
                return new MethodVisitor(Opcodes.ASM9, output) {
                    @Override
                    public void visitMethodInsn(
                            int opcode,
                            String owner,
                            String methodName,
                            String methodDescriptor,
                            boolean isInterface) {
                        if (opcode == Opcodes.INVOKEVIRTUAL
                                && "java/lang/String".equals(owner)
                                && "equalsIgnoreCase".equals(methodName)
                                && "(Ljava/lang/String;)Z".equals(methodDescriptor)) {
                            replacements++;
                            super.visitMethodInsn(
                                    Opcodes.INVOKESTATIC,
                                    RUNTIME,
                                    "spritesEquivalent",
                                    "(Ljava/lang/String;Ljava/lang/String;)Z",
                                    false);
                            return;
                        }
                        super.visitMethodInsn(opcode, owner, methodName, methodDescriptor, isInterface);
                    }
                };
            }
            return output;
        }

        private MethodVisitor normalizeArgumentAtEntry(MethodVisitor output) {
            replacements++;
            return new MethodVisitor(Opcodes.ASM9, output) {
                @Override
                public void visitCode() {
                    super.visitCode();
                    super.visitVarInsn(Opcodes.ALOAD, 1);
                    super.visitMethodInsn(
                            Opcodes.INVOKESTATIC,
                            RUNTIME,
                            "normalize",
                            "(Ljava/lang/String;)Ljava/lang/String;",
                            false);
                    super.visitVarInsn(Opcodes.ASTORE, 1);
                }
            };
        }

        private boolean isComplete() {
            return targetMethods == 1 && replacements == 1;
        }

        private String describe() {
            return "targetMethods=" + targetMethods + ",replacements=" + replacements;
        }
    }

    private static String sha256(byte[] bytes) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));
        } catch (Exception failure) {
            throw new IllegalStateException("SHA-256 unavailable", failure);
        }
    }
}
