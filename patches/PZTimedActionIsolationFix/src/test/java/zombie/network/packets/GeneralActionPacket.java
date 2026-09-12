package zombie.network.packets;

import zombie.core.Action;

public final class GeneralActionPacket extends Action {
    public GeneralActionPacket(int id, int playerId) {
        super(id, playerId);
    }
}
