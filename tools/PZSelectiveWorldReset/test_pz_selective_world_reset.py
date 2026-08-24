import struct
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from pz_selective_world_reset import (
    EMPTY_APOP_BYTES,
    LivestockZone,
    RESET_GUARD_MANIFEST,
    build_livestock_protection,
    build_region_invalidation_chunks,
    create_full_save_backup,
    main,
    parse_world_protection,
    read_animal_state_cells,
    read_region_header,
    read_reset_guard_manifest,
    region_hash,
    rollback_full_save,
    verify_full_save_backup,
    write_region_header,
)


def i32(value: int) -> bytes:
    return struct.pack(">i", value)


def i64(value: int) -> bytes:
    return struct.pack(">q", value)


def string_utf(value: str) -> bytes:
    encoded = value.encode("utf-8")
    return struct.pack(">h", len(encoded)) + encoded


def minimal_map_meta() -> bytes:
    payload = bytearray(b"META")
    payload += i32(249)
    payload += i32(0) * 4
    payload += i32(0)  # rooms
    payload += i32(0)  # buildings
    payload += i32(0)  # safehouses
    payload += i32(0)  # non-PVP zones
    payload += i32(0)  # factions
    payload += i32(0)  # designation zones
    return bytes(payload)


class WorldProtectionTests(unittest.TestCase):
    def test_reads_safehouses_and_livestock_designations(self):
        payload = bytearray(b"META")
        payload += i32(249)
        payload += i32(0) * 4  # one meta cell at 0,0
        payload += i32(0)  # rooms
        payload += i32(0)  # buildings
        payload += i32(1)  # safehouses
        payload += i32(100) + i32(200) + i32(20) + i32(30)
        payload += string_utf("owner") + i32(5000)
        payload += i32(1) + string_utf("member")
        payload += i64(123) + string_utf("home")
        payload += i64(456) + string_utf("Muldraugh")
        payload += i32(1) + string_utf("member")
        payload += i32(1)  # non-PVP zones
        payload += i32(1) + i32(2) + i32(3) + i32(4) + i32(5) + string_utf("peace")
        payload += i32(1)  # factions
        payload += string_utf("faction") + string_utf("owner") + i32(1)
        payload += b"\x01" + string_utf("TAG") + struct.pack(">fff", 0.1, 0.2, 0.3)
        payload += string_utf("member")
        payload += i32(2)  # designation zones
        payload += struct.pack(">d", 1234.5)
        payload += i32(120) + i32(220) + i32(0) + i32(12) + i32(18)
        payload += string_utf("AnimalZone") + string_utf("North ranch") + i32(42)
        payload += struct.pack(">d", 999.0)
        payload += i32(1) + i32(2) + i32(0) + i32(3) + i32(4)
        payload += string_utf("OtherZone") + string_utf("ignored") + i32(0)

        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "map_meta.bin"
            path.write_bytes(payload)
            version, safehouses, livestock = parse_world_protection(path)

        self.assertEqual(version, 249)
        self.assertEqual(len(safehouses), 1)
        self.assertEqual(safehouses[0].owner, "owner")
        self.assertEqual(len(livestock), 1)
        self.assertEqual((livestock[0].x, livestock[0].y), (120, 220))
        self.assertEqual((livestock[0].w, livestock[0].h), (18, 12))

    def test_only_nonempty_animal_cells_are_reported(self):
        with tempfile.TemporaryDirectory() as temporary:
            apop = Path(temporary)
            empty = i32(249) + bytes(EMPTY_APOP_BYTES - 4)
            (apop / "apop_10_20.bin").write_bytes(empty)
            populated = bytearray(empty)
            populated[-1] = 1
            (apop / "apop_-3_4.bin").write_bytes(populated)

            cells, files = read_animal_state_cells(apop)

        self.assertEqual(len(files), 2)
        self.assertEqual(len(cells), 1)
        self.assertEqual((cells[0].cell_x, cells[0].cell_y), (-3, 4))

    def test_only_livestock_zones_protect_map_chunks(self):
        zone = LivestockZone(42.0, 80, 160, 0, 8, 8, "Barn")
        areas, chunks = build_livestock_protection([zone], 0)

        self.assertEqual(len(areas), 1)
        self.assertEqual(areas[0].source, "livestock-zone")
        self.assertEqual(chunks, {(10, 20)})
        self.assertNotIn((-96, 128), chunks)  # apop_-3_4 cell origin

    def test_truncated_animal_cell_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            apop = Path(temporary)
            (apop / "apop_1_2.bin").write_bytes(i32(249))
            with self.assertRaisesRegex(ValueError, "truncated"):
                read_animal_state_cells(apop)

    def test_region_header_round_trip_and_reset_halo(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "RegionHeader.bin"
            entries = [region_hash(10, 20), region_hash(-1, 3)]
            write_region_header(path, 249, entries)
            self.assertEqual(read_region_header(path), (249, entries))
        halo = build_region_invalidation_chunks({(10, 20)})
        self.assertEqual(len(halo), 9)
        self.assertIn((9, 19), halo)
        self.assertIn((11, 21), halo)

    def test_complete_backup_and_atomic_rollback(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            save = root / "servertest"
            chunk = save / "map" / "10" / "20.bin"
            chunk.parent.mkdir(parents=True)
            chunk.write_bytes(b"original chunk")
            (save / "map_meta.bin").write_bytes(b"original metadata")
            nested = save / "mod-data" / "state.bin"
            nested.parent.mkdir()
            nested.write_bytes(b"original mod state")
            quarantine = root / "servertest-selective-reset-quarantine-20260824-120000"

            manifest = create_full_save_backup(save, quarantine, "servertest")
            verified = verify_full_save_backup(quarantine)
            self.assertEqual(manifest["fileCount"], 3)
            self.assertEqual(verified["verifiedFileCount"], 3)

            chunk.write_bytes(b"regenerated chunk")
            nested.write_bytes(b"new mod state")
            (save / "new-after-reset.bin").write_bytes(b"new")
            result = rollback_full_save(save, quarantine, "servertest")

            self.assertEqual(chunk.read_bytes(), b"original chunk")
            self.assertEqual(nested.read_bytes(), b"original mod state")
            self.assertFalse((save / "new-after-reset.bin").exists())
            previous = Path(result["previousSavePath"])
            self.assertEqual((previous / "map" / "10" / "20.bin").read_bytes(), b"regenerated chunk")
            self.assertEqual((previous / "new-after-reset.bin").read_bytes(), b"new")

    def test_rollback_rejects_backup_for_another_server(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            save = root / "servertest"
            (save / "map").mkdir(parents=True)
            (save / "map_meta.bin").write_bytes(b"metadata")
            quarantine = root / "servertest-selective-reset-quarantine-20260824-120000"
            create_full_save_backup(save, quarantine, "server2")

            with self.assertRaisesRegex(ValueError, "different server"):
                rollback_full_save(save, quarantine, "servertest")

    def test_cli_audit_apply_and_rollback(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            save = root / "servertest"
            chunk = save / "map" / "0" / "0.bin"
            chunk.parent.mkdir(parents=True)
            chunk.write_bytes(b"world before reset")
            (save / "map_meta.bin").write_bytes(minimal_map_meta())
            region_dir = save / "isoregiondata"
            region_dir.mkdir()
            reset_region = region_dir / "datachunk_0_0.bin"
            reset_region.write_bytes(b"stale region")
            unrelated_region = region_dir / "datachunk_9_9.bin"
            unrelated_region.write_bytes(b"unrelated region")
            write_region_header(
                region_dir / "RegionHeader.bin",
                249,
                [region_hash(0, 0), region_hash(9, 9)],
            )
            manual = root / "manual.json"
            manual.write_text("[]", encoding="utf-8")

            common = [
                "pz_selective_world_reset.py",
                "--save-root",
                str(save),
                "--server-name",
                "servertest-test-fixture",
                "--manual-areas",
                str(manual),
            ]
            with patch.object(sys, "argv", common + ["--report-dir", str(root / "audit")]):
                self.assertEqual(main(), 0)
            with patch.object(
                sys,
                "argv",
                common
                + [
                    "--report-dir",
                    str(root / "apply"),
                    "--apply",
                    "--confirmation",
                    "servertest-test-fixture",
                ],
            ):
                self.assertEqual(main(), 0)
            self.assertFalse(chunk.exists())
            self.assertFalse(reset_region.exists())
            self.assertTrue(unrelated_region.exists())
            self.assertEqual(
                read_region_header(region_dir / "RegionHeader.bin"),
                (249, [region_hash(9, 9)]),
            )
            vehicles, regions = read_reset_guard_manifest(save / RESET_GUARD_MANIFEST)
            self.assertEqual(vehicles, {(0, 0)})
            self.assertEqual(len(regions), 9)
            quarantine = next(root.glob("servertest-selective-reset-quarantine-*"))
            with patch.object(
                sys,
                "argv",
                common
                + [
                    "--report-dir",
                    str(root / "rollback"),
                    "--rollback",
                    "--quarantine",
                    str(quarantine),
                    "--confirmation",
                    "servertest-test-fixture",
                ],
            ):
                self.assertEqual(main(), 0)
            self.assertEqual(chunk.read_bytes(), b"world before reset")
            self.assertEqual(reset_region.read_bytes(), b"stale region")
            self.assertFalse((save / RESET_GUARD_MANIFEST).exists())


if __name__ == "__main__":
    unittest.main()
