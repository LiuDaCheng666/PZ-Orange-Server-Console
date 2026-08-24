package cn.zombiecommunity.pzstreaming;

import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.security.MessageDigest;
import java.security.ProtectionDomain;
import java.util.HexFormat;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.atomic.AtomicBoolean;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Label;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

public final class PZServerStreamingStabilityAgent {
    private static final String OBJECT_PACKET = "zombie/network/packets/ObjectModDataPacket";
    private static final String SERVER_MAP = "zombie/network/ServerMap";
    private static final String RUNTIME =
            "cn/zombiecommunity/pzstreaming/ObjectModDataRuntime";
    private static final Map<String, Set<String>> SUPPORTED_HASHES = Map.of(
            OBJECT_PACKET, Set.of(
                    "1d6f806ee95bf6d22f5a69d0535b375a60085039311697eecd6b85dff8e9d9c2"),
            SERVER_MAP, Set.of(
                    "b8bef308e1f556307cae3619be58cd39e0f6a97f1c94c00163529b25faf0ccc1",
                    "5a3e449c6b7f3ea237939502c5b43ab0dd490a3752fd675611aade7ae79c548d"));
    private static final AtomicBoolean INSTALLED = new AtomicBoolean();

    private PZServerStreamingStabilityAgent() {
    }

    public static void premain(String args, Instrumentation instrumentation) {
        if (!INSTALLED.compareAndSet(false, true)) {
            System.out.println("[PZStreaming] already installed");
            return;
        }
        instrumentation.addTransformer(new Transformer(), false);
        ObjectModDataRuntime.configure(args);
        System.out.println("[PZStreaming] agent installed; unsupported classes remain vanilla");
    }

    static byte[] transformForTest(String className, byte[] classfileBuffer) {
        return new Transformer().transform(null, className, null, null, classfileBuffer);
    }

    private static final class Transformer implements ClassFileTransformer {
        @Override
        public byte[] transform(
                ClassLoader loader,
                String className,
                Class<?> classBeingRedefined,
                ProtectionDomain protectionDomain,
                byte[] classfileBuffer) {
            Set<String> supportedHashes = SUPPORTED_HASHES.get(className);
            if (supportedHashes == null || !ObjectModDataRuntime.isEnabled()) {
                return null;
            }
            String actualHash = sha256(classfileBuffer);
            if (!supportedHashes.contains(actualHash)) {
                System.err.println("[PZStreaming] REFUSED " + className
                        + " unsupported SHA-256=" + actualHash + "; using vanilla class");
                return null;
            }

            try {
                ClassReader reader = new ClassReader(classfileBuffer);
                ClassWriter writer = new ClassWriter(reader, ClassWriter.COMPUTE_MAXS);
                if (OBJECT_PACKET.equals(className)) {
                    ObjectPacketVisitor visitor = new ObjectPacketVisitor(writer);
                    reader.accept(visitor, 0);
                    if (!visitor.isComplete()) {
                        System.err.println("[PZStreaming] REFUSED ObjectModDataPacket structure "
                                + visitor.describe() + "; using vanilla class");
                        return null;
                    }
                } else {
                    ServerMapVisitor visitor = new ServerMapVisitor(writer);
                    reader.accept(visitor, 0);
                    if (visitor.preupdateHooks != 1) {
                        System.err.println("[PZStreaming] REFUSED ServerMap hook count="
                                + visitor.preupdateHooks + "; using vanilla class");
                        return null;
                    }
                    ObjectModDataRuntime.markDrainHookActive();
                }
                System.out.println("[PZStreaming] ACTIVE " + className + " SHA-256=" + actualHash);
                return writer.toByteArray();
            } catch (Throwable failure) {
                System.err.println("[PZStreaming] REFUSED " + className
                        + " transform failed=" + failure + "; using vanilla class");
                return null;
            }
        }
    }

    private static final class ObjectPacketVisitor extends ClassVisitor {
        private int parseMethods;
        private int beginHooks;
        private int unresolvedHooks;
        private int consistentHooks;
        private int processHooks;

        private ObjectPacketVisitor(ClassVisitor delegate) {
            super(Opcodes.ASM9, delegate);
        }

        @Override
        public MethodVisitor visitMethod(
                int access,
                String name,
                String descriptor,
                String signature,
                String[] exceptions) {
            MethodVisitor output = super.visitMethod(access, name, descriptor, signature, exceptions);
            if ("parse".equals(name)
                    && "(Lzombie/core/network/ByteBufferReader;Lzombie/network/IConnection;)V"
                            .equals(descriptor)) {
                parseMethods++;
                return new MethodVisitor(Opcodes.ASM9, output) {
                    private boolean skippingNullWarning;
                    private int multiplayerFieldReads;

                    @Override
                    public void visitCode() {
                        super.visitCode();
                        super.visitVarInsn(Opcodes.ALOAD, 0);
                        super.visitVarInsn(Opcodes.ALOAD, 1);
                        super.visitVarInsn(Opcodes.ALOAD, 2);
                        super.visitMethodInsn(
                                Opcodes.INVOKESTATIC,
                                RUNTIME,
                                "begin",
                                "(Lzombie/network/packets/ObjectModDataPacket;"
                                        + "Lzombie/core/network/ByteBufferReader;"
                                        + "Lzombie/network/IConnection;)V",
                                false);
                        beginHooks++;
                    }

                    @Override
                    public void visitFieldInsn(
                            int opcode,
                            String owner,
                            String fieldName,
                            String fieldDescriptor) {
                        if (!skippingNullWarning
                                && opcode == Opcodes.GETSTATIC
                                && "zombie/debug/DebugType".equals(owner)
                                && "Multiplayer".equals(fieldName)
                                && multiplayerFieldReads++ == 0) {
                            skippingNullWarning = true;
                            return;
                        }
                        if (!skippingNullWarning) {
                            super.visitFieldInsn(opcode, owner, fieldName, fieldDescriptor);
                        }
                    }

                    @Override
                    public void visitInsn(int opcode) {
                        if (!skippingNullWarning) {
                            super.visitInsn(opcode);
                        }
                    }

                    @Override
                    public void visitIntInsn(int opcode, int operand) {
                        if (!skippingNullWarning) {
                            super.visitIntInsn(opcode, operand);
                        }
                    }

                    @Override
                    public void visitVarInsn(int opcode, int variable) {
                        if (!skippingNullWarning) {
                            super.visitVarInsn(opcode, variable);
                        }
                    }

                    @Override
                    public void visitTypeInsn(int opcode, String type) {
                        if (!skippingNullWarning) {
                            super.visitTypeInsn(opcode, type);
                        }
                    }

                    @Override
                    public void visitLdcInsn(Object value) {
                        if (!skippingNullWarning) {
                            super.visitLdcInsn(value);
                        }
                    }

                    @Override
                    public void visitMethodInsn(
                            int opcode,
                            String owner,
                            String methodName,
                            String methodDescriptor,
                            boolean isInterface) {
                        if (skippingNullWarning
                                && opcode == Opcodes.INVOKEVIRTUAL
                                && "zombie/debug/DebugType".equals(owner)
                                && "warn".equals(methodName)
                                && "(Ljava/lang/String;[Ljava/lang/Object;)V".equals(methodDescriptor)) {
                            super.visitVarInsn(Opcodes.ALOAD, 0);
                            super.visitVarInsn(Opcodes.ALOAD, 1);
                            super.visitVarInsn(Opcodes.ALOAD, 2);
                            super.visitMethodInsn(
                                    Opcodes.INVOKESTATIC,
                                    RUNTIME,
                                    "handleUnresolved",
                                    "(Lzombie/network/packets/ObjectModDataPacket;"
                                            + "Lzombie/core/network/ByteBufferReader;"
                                            + "Lzombie/network/IConnection;)V",
                                    false);
                            unresolvedHooks++;
                            skippingNullWarning = false;
                            return;
                        }
                        if (!skippingNullWarning) {
                            super.visitMethodInsn(opcode, owner, methodName, methodDescriptor, isInterface);
                        }
                    }
                };
            }
            if ("isConsistent".equals(name)
                    && "(Lzombie/network/IConnection;)Z".equals(descriptor)) {
                consistentHooks++;
                return earlyReturnIfHandled(output, true);
            }
            if ("processServer".equals(name)
                    && "(Lzombie/network/PacketTypes$PacketType;"
                            .concat("Lzombie/core/raknet/UdpConnection;)V").equals(descriptor)) {
                processHooks++;
                return earlyReturnIfHandled(output, false);
            }
            return output;
        }

        private MethodVisitor earlyReturnIfHandled(MethodVisitor output, boolean consistentMethod) {
            return new MethodVisitor(Opcodes.ASM9, output) {
                @Override
                public void visitCode() {
                    super.visitCode();
                    Label vanilla = new Label();
                    super.visitVarInsn(Opcodes.ALOAD, 0);
                    super.visitMethodInsn(
                            Opcodes.INVOKESTATIC,
                            RUNTIME,
                            consistentMethod ? "isHandled" : "consumeHandled",
                            "(Lzombie/network/packets/ObjectModDataPacket;)Z",
                            false);
                    super.visitJumpInsn(Opcodes.IFEQ, vanilla);
                    if (consistentMethod) {
                        super.visitInsn(Opcodes.ICONST_1);
                        super.visitInsn(Opcodes.IRETURN);
                    } else {
                        super.visitInsn(Opcodes.RETURN);
                    }
                    super.visitLabel(vanilla);
                    super.visitFrame(Opcodes.F_SAME, 0, null, 0, null);
                }
            };
        }

        private boolean isComplete() {
            return parseMethods == 1
                    && beginHooks == 1
                    && unresolvedHooks == 1
                    && consistentHooks == 1
                    && processHooks == 1;
        }

        private String describe() {
            return "parse=" + parseMethods
                    + ",begin=" + beginHooks
                    + ",unresolved=" + unresolvedHooks
                    + ",consistent=" + consistentHooks
                    + ",process=" + processHooks;
        }
    }

    private static final class ServerMapVisitor extends ClassVisitor {
        private int preupdateHooks;

        private ServerMapVisitor(ClassVisitor delegate) {
            super(Opcodes.ASM9, delegate);
        }

        @Override
        public MethodVisitor visitMethod(
                int access,
                String name,
                String descriptor,
                String signature,
                String[] exceptions) {
            MethodVisitor output = super.visitMethod(access, name, descriptor, signature, exceptions);
            if (!"preupdate".equals(name) || !"()V".equals(descriptor)) {
                return output;
            }
            preupdateHooks++;
            return new MethodVisitor(Opcodes.ASM9, output) {
                @Override
                public void visitCode() {
                    super.visitCode();
                    super.visitMethodInsn(
                            Opcodes.INVOKESTATIC,
                            RUNTIME,
                            "drain",
                            "()V",
                            false);
                }
            };
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
