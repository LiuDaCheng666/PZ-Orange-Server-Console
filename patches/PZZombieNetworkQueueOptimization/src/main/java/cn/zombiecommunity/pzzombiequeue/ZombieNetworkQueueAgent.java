package cn.zombiecommunity.pzzombiequeue;

import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.security.MessageDigest;
import java.security.ProtectionDomain;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Label;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

public final class ZombieNetworkQueueAgent {
    static final String TARGET = "zombie/popman/NetworkZombiePacker";
    static final String TARGET_HASH =
            "5b202038b360877e8a308265e6bf7ce720e34d0c3670adfb3a7c5dbddaf5197e";
    private static final String NETWORK_ZOMBIE =
            "zombie/popman/NetworkZombieList$NetworkZombie";
    private static final String LINKED_LIST = "java/util/LinkedList";
    private static final String RUNTIME =
            "cn/zombiecommunity/pzzombiequeue/ZombieNetworkQueueRuntime";
    private static final AtomicBoolean INSTALLED = new AtomicBoolean();

    private ZombieNetworkQueueAgent() { }

    public static void premain(String args, Instrumentation instrumentation) {
        install(args, instrumentation, false);
    }

    public static void agentmain(String args, Instrumentation instrumentation) {
        install(args, instrumentation, true);
    }

    private static void install(String args, Instrumentation instrumentation, boolean retransform) {
        if (!INSTALLED.compareAndSet(false, true)) {
            System.out.println("[PZZombieQueue] already installed");
            return;
        }
        Config config = Config.parse(args);
        ZombieNetworkQueueRuntime.start(config.enabled(), config.threshold(),
                config.linearQueries(), config.reportSeconds());
        Transformer transformer = new Transformer();
        instrumentation.addTransformer(transformer, retransform);
        System.out.println("[PZZombieQueue] agent installed enabled=" + config.enabled()
                + " threshold=" + config.threshold()
                + " linearQueries=" + config.linearQueries()
                + " reportSeconds=" + config.reportSeconds());
        if (!retransform) return;

        Class<?> target = null;
        for (Class<?> loaded : instrumentation.getAllLoadedClasses()) {
            if (TARGET.equals(loaded.getName().replace('.', '/'))
                    && instrumentation.isModifiableClass(loaded)) {
                target = loaded;
                break;
            }
        }
        if (target == null) {
            System.out.println("[PZZombieQueue] target not loaded; waiting for normal class load");
            return;
        }
        try {
            instrumentation.retransformClasses(target);
        } catch (Exception | LinkageError | OutOfMemoryError failure) {
            instrumentation.removeTransformer(transformer);
            throw new IllegalStateException("NetworkZombiePacker retransform failed", failure);
        }
        if (transformer.lastHookCount != 1) {
            instrumentation.removeTransformer(transformer);
            throw new IllegalStateException(
                    "Unexpected NetworkZombiePacker hook count=" + transformer.lastHookCount);
        }
    }

    static byte[] transformForTest(String className, byte[] bytes) {
        return new Transformer().transform(null, className, null, null, bytes);
    }

    static boolean matchesContractForTest(byte[] bytes) {
        return ContractScanner.scan(bytes).matches();
    }

    static String sha256ForTest(byte[] bytes) {
        return sha256(bytes);
    }

    private static final class Transformer implements ClassFileTransformer {
        volatile int lastHookCount;

        @Override
        public byte[] transform(ClassLoader loader, String className, Class<?> classBeingRedefined,
                ProtectionDomain protectionDomain, byte[] bytes) {
            if (!TARGET.equals(className)) return null;
            String hash = sha256(bytes);
            if (!TARGET_HASH.equals(hash)) {
                System.err.println("[PZZombieQueue] REFUSED unsupported " + className
                        + " SHA-256=" + hash + "; using vanilla class");
                return null;
            }
            try {
                Contract contract = ContractScanner.scan(bytes);
                if (!contract.matches()) {
                    System.err.println("[PZZombieQueue] REFUSED bytecode contract: "
                            + contract.reason() + "; using vanilla class");
                    return null;
                }
                int[] hooks = {0};
                ClassReader reader = new ClassReader(bytes);
                ClassWriter writer = new ClassWriter(reader, ClassWriter.COMPUTE_MAXS);
                reader.accept(new TransformVisitor(writer, hooks), 0);
                lastHookCount = hooks[0];
                if (hooks[0] != 1) {
                    System.err.println("[PZZombieQueue] REFUSED transformed hookCount="
                            + hooks[0] + "; using vanilla class");
                    return null;
                }
                System.out.println("[PZZombieQueue] ACTIVE " + className
                        + " SHA-256=" + hash);
                return writer.toByteArray();
            } catch (RuntimeException | LinkageError | OutOfMemoryError failure) {
                System.err.println("[PZZombieQueue] REFUSED transform failed=" + failure
                        + "; using vanilla class");
                return null;
            }
        }
    }

    private static final class TransformVisitor extends ClassVisitor {
        private final int[] hooks;

        TransformVisitor(ClassVisitor output, int[] hooks) {
            super(Opcodes.ASM9, output);
            this.hooks = hooks;
        }

        @Override
        public MethodVisitor visitMethod(int access, String name, String descriptor,
                String signature, String[] exceptions) {
            MethodVisitor output = super.visitMethod(access, name, descriptor, signature, exceptions);
            if (!"postupdate".equals(name) || !"()V".equals(descriptor)) return output;
            return new CleanupMethodVisitor(output, hooks);
        }
    }

    private static final class CleanupMethodVisitor extends MethodVisitor {
        private final int[] hooks;
        private final Label protectedStart = new Label();
        private final Label protectedEnd = new Label();
        private final Label cleanupHandler = new Label();

        CleanupMethodVisitor(MethodVisitor output, int[] hooks) {
            super(Opcodes.ASM9, output);
            this.hooks = hooks;
        }

        @Override
        public void visitCode() {
            super.visitCode();
            super.visitMethodInsn(Opcodes.INVOKESTATIC, RUNTIME, "enter", "()V", false);
            super.visitLabel(protectedStart);
        }

        @Override
        public void visitMethodInsn(int opcode, String owner, String name,
                String descriptor, boolean isInterface) {
            if (opcode == Opcodes.INVOKEVIRTUAL && LINKED_LIST.equals(owner)
                    && "contains".equals(name)
                    && "(Ljava/lang/Object;)Z".equals(descriptor)) {
                hooks[0]++;
                super.visitMethodInsn(Opcodes.INVOKESTATIC, RUNTIME, "containsAndReserve",
                        "(Ljava/util/LinkedList;Ljava/lang/Object;)Z", false);
                return;
            }
            super.visitMethodInsn(opcode, owner, name, descriptor, isInterface);
        }

        @Override
        public void visitInsn(int opcode) {
            if (opcode == Opcodes.RETURN) {
                super.visitMethodInsn(Opcodes.INVOKESTATIC, RUNTIME, "exit", "()V", false);
            }
            super.visitInsn(opcode);
        }

        @Override
        public void visitMaxs(int maxStack, int maxLocals) {
            super.visitLabel(protectedEnd);
            // Appending the catch-all after the original handlers preserves monitor-finally order.
            super.visitTryCatchBlock(protectedStart, protectedEnd, cleanupHandler,
                    "java/lang/Throwable");
            super.visitLabel(cleanupHandler);
            super.visitFrame(Opcodes.F_FULL, 1, new Object[] {TARGET}, 1,
                    new Object[] {"java/lang/Throwable"});
            super.visitMethodInsn(Opcodes.INVOKESTATIC, RUNTIME, "exit", "()V", false);
            super.visitInsn(Opcodes.ATHROW);
            super.visitMaxs(maxStack, maxLocals);
        }
    }

    private record Contract(boolean matches, String reason) { }

    private static final class ContractScanner extends ClassVisitor {
        private int postupdateMethods;
        private List<Instruction> instructions;

        private ContractScanner() {
            super(Opcodes.ASM9);
        }

        static Contract scan(byte[] bytes) {
            ContractScanner scanner = new ContractScanner();
            ClassReader reader = new ClassReader(bytes);
            if (!TARGET.equals(reader.getClassName())) {
                return new Contract(false, "wrong class " + reader.getClassName());
            }
            reader.accept(scanner, ClassReader.SKIP_DEBUG | ClassReader.SKIP_FRAMES);
            if (scanner.postupdateMethods != 1 || scanner.instructions == null) {
                return new Contract(false,
                        "postupdate()V count=" + scanner.postupdateMethods);
            }
            return scanner.checkInstructions();
        }

        @Override
        public MethodVisitor visitMethod(int access, String name, String descriptor,
                String signature, String[] exceptions) {
            if (!"postupdate".equals(name) || !"()V".equals(descriptor)) return null;
            postupdateMethods++;
            List<Instruction> methodInstructions = new ArrayList<>();
            instructions = methodInstructions;
            return new MethodVisitor(Opcodes.ASM9) {
                @Override
                public void visitInsn(int opcode) {
                    methodInstructions.add(Instruction.simple(opcode));
                }

                @Override
                public void visitVarInsn(int opcode, int variable) {
                    methodInstructions.add(Instruction.variable(opcode, variable));
                }

                @Override
                public void visitFieldInsn(int opcode, String owner, String field,
                        String fieldDescriptor) {
                    methodInstructions.add(Instruction.member(
                            opcode, owner, field, fieldDescriptor));
                }

                @Override
                public void visitMethodInsn(int opcode, String owner, String method,
                        String calledDescriptor, boolean isInterface) {
                    methodInstructions.add(Instruction.member(
                            opcode, owner, method, calledDescriptor));
                }

                @Override
                public void visitJumpInsn(int opcode, Label label) {
                    methodInstructions.add(Instruction.simple(opcode));
                }

                @Override
                public void visitIntInsn(int opcode, int operand) {
                    methodInstructions.add(Instruction.simple(opcode));
                }

                @Override
                public void visitTypeInsn(int opcode, String type) {
                    methodInstructions.add(Instruction.member(opcode, type, null, null));
                }

                @Override
                public void visitLdcInsn(Object value) {
                    methodInstructions.add(Instruction.simple(Opcodes.LDC));
                }

                @Override
                public void visitIincInsn(int variable, int increment) {
                    methodInstructions.add(Instruction.variable(Opcodes.IINC, variable));
                }

                @Override
                public void visitInvokeDynamicInsn(String name, String descriptor,
                        org.objectweb.asm.Handle bootstrapMethodHandle,
                        Object... bootstrapMethodArguments) {
                    methodInstructions.add(Instruction.member(
                            Opcodes.INVOKEDYNAMIC, null, name, descriptor));
                }
            };
        }

        private Contract checkInstructions() {
            List<Integer> containsIndexes = new ArrayList<>();
            for (int index = 0; index < instructions.size(); index++) {
                Instruction instruction = instructions.get(index);
                if (instruction.isMember(Opcodes.INVOKEVIRTUAL, LINKED_LIST, "contains",
                        "(Ljava/lang/Object;)Z")) {
                    containsIndexes.add(index);
                }
            }
            if (containsIndexes.size() != 1) {
                return new Contract(false,
                        "LinkedList.contains count=" + containsIndexes.size());
            }
            int index = containsIndexes.get(0);
            if (index < 3 || index + 6 >= instructions.size()) {
                return new Contract(false, "contains/add instruction window truncated");
            }
            Instruction loadList = instructions.get(index - 3);
            Instruction getList = instructions.get(index - 2);
            Instruction loadZombie = instructions.get(index - 1);
            if (loadList.opcode != Opcodes.ALOAD || loadZombie.opcode != Opcodes.ALOAD
                    || !getList.isMember(Opcodes.GETFIELD, NETWORK_ZOMBIE, "zombies",
                            "Ljava/util/LinkedList;")) {
                return new Contract(false, "contains receiver/candidate shape changed");
            }
            if (instructions.get(index + 1).opcode != Opcodes.IFNE
                    || !instructions.get(index + 2).isVariable(Opcodes.ALOAD, loadList.variable)
                    || !instructions.get(index + 3).sameMember(getList)
                    || !instructions.get(index + 4).isVariable(
                            Opcodes.ALOAD, loadZombie.variable)
                    || !instructions.get(index + 5).isMember(Opcodes.INVOKEVIRTUAL,
                            LINKED_LIST, "add", "(Ljava/lang/Object;)Z")
                    || instructions.get(index + 6).opcode != Opcodes.POP) {
                return new Contract(false, "same-list conditional add contract changed");
            }
            return new Contract(true, "matched");
        }
    }

    private static final class Instruction {
        final int opcode;
        final int variable;
        final String owner;
        final String name;
        final String descriptor;

        private Instruction(int opcode, int variable, String owner, String name,
                String descriptor) {
            this.opcode = opcode;
            this.variable = variable;
            this.owner = owner;
            this.name = name;
            this.descriptor = descriptor;
        }

        static Instruction simple(int opcode) {
            return new Instruction(opcode, -1, null, null, null);
        }

        static Instruction variable(int opcode, int variable) {
            return new Instruction(opcode, variable, null, null, null);
        }

        static Instruction member(int opcode, String owner, String name, String descriptor) {
            return new Instruction(opcode, -1, owner, name, descriptor);
        }

        boolean isVariable(int expectedOpcode, int expectedVariable) {
            return opcode == expectedOpcode && variable == expectedVariable;
        }

        boolean isMember(int expectedOpcode, String expectedOwner, String expectedName,
                String expectedDescriptor) {
            return opcode == expectedOpcode
                    && java.util.Objects.equals(owner, expectedOwner)
                    && java.util.Objects.equals(name, expectedName)
                    && java.util.Objects.equals(descriptor, expectedDescriptor);
        }

        boolean sameMember(Instruction other) {
            return isMember(other.opcode, other.owner, other.name, other.descriptor);
        }
    }

    private static String sha256(byte[] bytes) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));
        } catch (Exception failure) {
            throw new IllegalStateException("SHA-256 unavailable", failure);
        }
    }

    static record Config(boolean enabled, int threshold, int linearQueries, long reportSeconds) {
        static Config parse(String args) {
            boolean enabled = true;
            int threshold = 64;
            int linearQueries = 3;
            long reportSeconds = 300L;
            if (args != null && !args.isBlank()) {
                for (String token : args.split(",")) {
                    String[] pair = token.split("=", 2);
                    if (pair.length != 2) continue;
                    String key = pair[0].trim();
                    String value = pair[1].trim();
                    try {
                        switch (key) {
                            case "enabled" -> {
                                if ("true".equalsIgnoreCase(value)) enabled = true;
                                else if ("false".equalsIgnoreCase(value)) enabled = false;
                                else throw new IllegalArgumentException("not a boolean");
                            }
                            case "threshold" -> threshold = clamp(
                                    Integer.parseInt(value), 64, 1_000_000);
                            case "linearQueries" -> linearQueries = clamp(
                                    Integer.parseInt(value), 3, 1_024);
                            case "reportSeconds" -> reportSeconds = clamp(
                                    Long.parseLong(value), 30L, 86_400L);
                            default -> { }
                        }
                    } catch (RuntimeException invalid) {
                        System.err.println("[PZZombieQueue] ignored invalid option " + token);
                    }
                }
            }
            return new Config(enabled, threshold, linearQueries, reportSeconds);
        }

        private static int clamp(int value, int minimum, int maximum) {
            return Math.max(minimum, Math.min(maximum, value));
        }

        private static long clamp(long value, long minimum, long maximum) {
            return Math.max(minimum, Math.min(maximum, value));
        }
    }
}
