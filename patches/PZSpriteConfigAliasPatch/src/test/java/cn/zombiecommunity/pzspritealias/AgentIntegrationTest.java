package cn.zombiecommunity.pzspritealias;

public final class AgentIntegrationTest {
    private static final String[] TARGETS = {
        "zombie.entity.components.spriteconfig.SpriteConfigManager$ObjectInfo",
        "zombie.entity.components.spriteconfig.SpriteConfigManager$FaceInfo",
        "zombie.entity.components.spriteconfig.SpriteConfigManager$TileInfo"
    };

    private AgentIntegrationTest() {
    }

    public static void main(String[] args) throws Exception {
        for (String target : TARGETS) {
            Class.forName(target);
            if (!PZSpriteConfigAliasAgent.wasActivated(target.replace('.', '/'))) {
                throw new AssertionError("transformer was not activated for " + target);
            }
        }
        System.out.println("PZ SpriteConfig alias Java agent integration test passed");
    }
}
