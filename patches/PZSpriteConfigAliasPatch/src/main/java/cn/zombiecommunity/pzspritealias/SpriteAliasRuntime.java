package cn.zombiecommunity.pzspritealias;

import java.util.Map;

public final class SpriteAliasRuntime {
    private static final Map<String, String> ALIASES = Map.ofEntries(
            Map.entry("ct_oac_fixtures_counters_01_33", "fixtures_counters_01_33"),
            Map.entry("ct_oac_fixtures_counters_01_35", "fixtures_counters_01_35"),
            Map.entry("ct_oac_fixtures_counters_01_37", "fixtures_counters_01_37"),
            Map.entry("ct_oac_fixtures_counters_01_39", "fixtures_counters_01_39"),
            Map.entry("ct_oac_furniture_storage_02_0", "furniture_storage_02_0"),
            Map.entry("ct_oac_furniture_storage_02_1", "furniture_storage_02_1"),
            Map.entry("ct_oac_furniture_storage_02_2", "furniture_storage_02_2"),
            Map.entry("ct_oac_furniture_storage_02_3", "furniture_storage_02_3"),
            Map.entry("ct_oac_furniture_storage_02_8", "furniture_storage_02_8"),
            Map.entry("ct_oac_furniture_storage_02_9", "furniture_storage_02_9"),
            Map.entry("ct_oac_furniture_storage_02_10", "furniture_storage_02_10"),
            Map.entry("ct_oac_furniture_storage_02_11", "furniture_storage_02_11"),
            Map.entry("ct_oac_carpentry_02_8", "carpentry_02_8"),
            Map.entry("ct_oac_carpentry_02_9", "carpentry_02_9"),
            Map.entry("ct_oac_carpentry_02_10", "carpentry_02_10"),
            Map.entry("ct_oac_carpentry_02_11", "carpentry_02_11"),
            Map.entry("fixtures_windows_01_2", "fixtures_windows_01_0"),
            Map.entry("fixtures_windows_01_3", "fixtures_windows_01_1"),
            Map.entry("fixtures_windows_01_4", "fixtures_windows_01_0"),
            Map.entry("fixtures_windows_01_5", "fixtures_windows_01_1"),
            Map.entry("fixtures_windows_01_6", "fixtures_windows_01_0"),
            Map.entry("fixtures_windows_01_7", "fixtures_windows_01_1"),
            Map.entry("LS_Inventions_10", "LS_Inventions_4"),
            Map.entry("LS_Inventions_11", "LS_Inventions_5"));

    private SpriteAliasRuntime() {
    }

    public static String normalize(String spriteName) {
        if (spriteName == null || spriteName.length() < 2) {
            return spriteName;
        }
        char first = spriteName.charAt(0);
        if (first != 'c' && first != 'f' && first != 'L') {
            return spriteName;
        }
        return ALIASES.getOrDefault(spriteName, spriteName);
    }

    public static boolean spritesEquivalent(String actual, String expected) {
        if (actual == null || expected == null) {
            return false;
        }
        return normalize(actual).equalsIgnoreCase(normalize(expected));
    }

    public static int aliasCount() {
        return ALIASES.size();
    }
}
