package cn.zombiecommunity.pzglassguard;

import java.util.ArrayList;
import java.util.List;
import zombie.core.properties.IsoPropertyType;
import zombie.core.properties.PropertyContainer;
import zombie.iso.IsoDirections;
import zombie.iso.IsoGridSquare;
import zombie.iso.IsoObject;
import zombie.iso.objects.IsoLightSwitch;
import zombie.iso.objects.IsoWindow;
import zombie.util.list.PZArrayList;

public final class GlassAttachmentCleanup {
    private static final int DEFAULT_MAX_OBJECTS = 512;
    private static final int HARD_MAX_OBJECTS = 4096;

    private GlassAttachmentCleanup() {
    }

    public static void removeGlassAttachments(IsoGridSquare square, IsoWindow window) {
        if (square == null || window == null) {
            return;
        }

        PZArrayList<IsoObject> objects = square.getObjects();
        int originalSize = objects == null ? 0 : objects.size();
        if (originalSize <= 0) {
            return;
        }

        int configuredLimit = Integer.getInteger("pz.glassGuard.maxObjects", DEFAULT_MAX_OBJECTS);
        int limit = Math.max(1, Math.min(configuredLimit, HARD_MAX_OBJECTS));
        int snapshotSize = Math.min(originalSize, limit);
        List<IsoObject> snapshot = new ArrayList<>(snapshotSize);
        for (int index = 0; index < snapshotSize; index++) {
            snapshot.add(objects.get(index));
        }

        if (originalSize > limit) {
            warn(square, "object list was capped", null,
                    "size=" + originalSize + " limit=" + limit);
        }

        IsoDirections firstDirection = window.getNorth() ? IsoDirections.N : IsoDirections.W;
        IsoDirections secondDirection = window.getNorth() ? IsoDirections.S : IsoDirections.E;

        int removed = 0;
        int failed = 0;
        for (IsoObject object : snapshot) {
            if (!shouldRemove(object, firstDirection, secondDirection)) {
                continue;
            }

            int before = objects.size();
            if (!objects.contains(object)) {
                continue;
            }

            try {
                square.RemoveTileObject(object);
            } catch (Throwable failure) {
                failed++;
                warn(square, "attachment removal threw", object,
                        failure.getClass().getName() + ": " + String.valueOf(failure.getMessage()));
                continue;
            }

            int after = objects.size();
            if (after < before || !objects.contains(object)) {
                removed++;
            } else {
                failed++;
                warn(square, "attachment was not removed; skipped to prevent an infinite loop",
                        object, "sizeBefore=" + before + " sizeAfter=" + after);
            }
        }

        if (failed > 0) {
            warn(square, "cleanup completed with guarded failures", null,
                    "removed=" + removed + " failed=" + failed + " snapshot=" + snapshotSize);
        }
    }

    private static boolean shouldRemove(
            IsoObject object,
            IsoDirections firstDirection,
            IsoDirections secondDirection) {
        if (object == null || object.getSprite() == null) {
            return false;
        }

        PropertyContainer properties = object.getProperties();
        if (properties == null) {
            return false;
        }

        if (properties.has(IsoPropertyType.ATTACHED_TO_GLASS)) {
            return true;
        }

        if (!(object instanceof IsoLightSwitch)) {
            return false;
        }

        boolean moveableWallObject = properties.has(IsoPropertyType.IS_MOVE_ABLE)
                && (properties.has(IsoPropertyType.IS_HIGH)
                    || "WallObject".equals(properties.get(IsoPropertyType.MOVE_TYPE)));
        if (!moveableWallObject) {
            return false;
        }

        IsoDirections facing = object.getFacing();
        return facing == firstDirection || facing == secondDirection;
    }

    private static void warn(IsoGridSquare square, String message, IsoObject object, String detail) {
        String objectType = object == null ? "n/a" : object.getClass().getName();
        String sprite = "n/a";
        if (object != null) {
            try {
                sprite = String.valueOf(object.getTextureName());
            } catch (Throwable ignored) {
                // Logging must never interfere with world processing.
            }
        }
        System.err.println("[PZGlassRemovalGuard] WARN x=" + square.getX()
                + " y=" + square.getY() + " z=" + square.getZ()
                + " message=" + message + " object=" + objectType
                + " sprite=" + sprite + " " + detail);
    }
}
