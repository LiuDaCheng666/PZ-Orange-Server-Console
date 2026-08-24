package cn.zombiecommunity.pzentityguard;

import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import zombie.entity.Engine;
import zombie.entity.GameEntity;
import zombie.entity.GameEntityType;
import zombie.entity.util.ObjectSet;
import zombie.iso.IsoGridSquare;

public final class EntityRegistrationIntegrationTest {
    private EntityRegistrationIntegrationTest() {
    }

    public static void main(String[] args) throws Exception {
        Engine engine = new Engine();
        Field managerField = Engine.class.getDeclaredField("entityManager");
        managerField.setAccessible(true);
        Object manager = managerField.get(engine);

        Field setField = manager.getClass().getDeclaredField("entitySet");
        setField.setAccessible(true);
        @SuppressWarnings("unchecked")
        ObjectSet<GameEntity> set = (ObjectSet<GameEntity>) setField.get(manager);

        Method addInternal = manager.getClass().getDeclaredMethod("addEntityInternal", GameEntity.class);
        addInternal.setAccessible(true);
        Field added = GameEntity.class.getDeclaredField("addedToEngine");
        Field scheduledRemoval = GameEntity.class.getDeclaredField("scheduledForEngineRemoval");
        added.setAccessible(true);
        scheduledRemoval.setAccessible(true);

        TestEntity idempotent = new TestEntity(1);
        set.add(idempotent);
        added.setBoolean(idempotent, true);
        addInternal.invoke(manager, idempotent);
        if (EntityRegistrationGuardRuntime.suppressedCount() != 1) {
            throw new AssertionError("idempotent duplicate was not suppressed");
        }

        TestEntity inconsistent = new TestEntity(2);
        set.add(inconsistent);
        expectOriginalFailure(addInternal, manager, inconsistent);

        TestEntity removing = new TestEntity(3);
        set.add(removing);
        added.setBoolean(removing, true);
        scheduledRemoval.setBoolean(removing, true);
        expectOriginalFailure(addInternal, manager, removing);

        System.out.println("PZ entity-registration guard integration tests passed");
    }

    private static void expectOriginalFailure(Method method, Object manager, GameEntity entity) throws Exception {
        try {
            method.invoke(manager, entity);
            throw new AssertionError("original duplicate failure was unexpectedly suppressed");
        } catch (InvocationTargetException expected) {
            if (!(expected.getCause() instanceof IllegalArgumentException)
                    || !expected.getCause().getMessage().startsWith("Entity is already registered")) {
                throw expected;
            }
        }
    }

    private static final class TestEntity extends GameEntity {
        private final long id;

        private TestEntity(long id) {
            this.id = id;
        }

        @Override
        public GameEntityType getGameEntityType() {
            return null;
        }

        @Override
        public IsoGridSquare getSquare() {
            return null;
        }

        @Override
        public long getEntityNetID() {
            return id;
        }

        @Override
        public float getX() {
            return 0;
        }

        @Override
        public float getY() {
            return 0;
        }

        @Override
        public float getZ() {
            return 0;
        }

        @Override
        public boolean isEntityValid() {
            return true;
        }
    }
}
