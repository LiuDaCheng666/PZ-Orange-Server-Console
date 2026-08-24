package zombie.core;

import zombie.network.fields.character.PlayerID;

public class Action {
    protected byte id;
    protected final PlayerID playerId;
    public boolean stopped;

    public Action(int id, int playerId) {
        this.id = (byte) id;
        this.playerId = new PlayerID((short) playerId);
    }

    void stop() {
        stopped = true;
    }
}
