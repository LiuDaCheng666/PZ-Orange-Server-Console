import json
import os
import struct
import sys
import tempfile
import unittest
import zipfile
import zlib
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))

from pz_chunk_recovery import (
    TRANSACTION_MANIFEST,
    audit_chunks,
    enumerate_backups,
    inspect_backup,
    list_safehouses,
    restore_chunks,
    rollback_transaction,
    startup_gate,
    validate_chunk_bytes,
)


def i32(value: int) -> bytes:
    return struct.pack(">i", value)


def i64(value: int) -> bytes:
    return struct.pack(">q", value)


def string_utf(value: str) -> bytes:
    encoded = value.encode("utf-8")
    return struct.pack(">h", len(encoded)) + encoded


def map_meta_with_safehouse() -> bytes:
    payload = bytearray(b"META")
    payload += i32(249) + i32(0) * 4
    payload += i32(0) + i32(0)  # rooms and buildings
    payload += i32(1)
    payload += i32(10698) + i32(9481) + i32(12) + i32(10)
    payload += string_utf("acid") + i32(5000)
    payload += i32(1) + string_utf("erica")
    payload += i64(123) + string_utf("Acid Home")
    payload += i64(456) + string_utf("Muldraugh")
    payload += i32(0)
    payload += i32(0) + i32(0) + i32(0)
    return bytes(payload)


def chunk_payload(body: bytes = b"valid chunk", version: int = 249) -> bytes:
    crc = zlib.crc32(body) & 0xFFFFFFFF
    length = 17 + len(body)
    return b"\x00" + struct.pack(">IIQ", version, length, crc) + body


class ChunkRecoveryTests(unittest.TestCase):
    def test_lists_safehouse_members_and_covering_chunks(self):
        with tempfile.TemporaryDirectory() as temporary:
            save = Path(temporary)
            (save / "map_meta.bin").write_bytes(map_meta_with_safehouse())
            result = list_safehouses(save)
        self.assertEqual(result["safehouseCount"], 1)
        safehouse = result["safehouses"][0]
        self.assertEqual(safehouse["owner"], "acid")
        self.assertEqual(safehouse["players"], ["erica"])
        self.assertIn({"wx": 1337, "wy": 1185}, safehouse["chunks"])
        self.assertIn({"wx": 1338, "wy": 1186}, safehouse["chunks"])
    def test_validates_length_and_crc(self):
        valid = chunk_payload()
        self.assertTrue(validate_chunk_bytes(valid)["valid"])
        wrong_crc = bytearray(valid)
        wrong_crc[-1] ^= 1
        self.assertEqual(validate_chunk_bytes(bytes(wrong_crc))["reason"], "crc-mismatch")
        wrong_length = bytearray(valid)
        struct.pack_into(">I", wrong_length, 5, len(valid) + 1)
        self.assertEqual(validate_chunk_bytes(bytes(wrong_length))["reason"], "length-mismatch")

    def test_audit_reports_only_invalid_chunks(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            save = root / "servertest"
            (save / "map" / "1").mkdir(parents=True)
            (save / "map" / "1" / "2.bin").write_bytes(chunk_payload(b"ok"))
            broken = bytearray(chunk_payload(b"bad"))
            broken[-1] ^= 1
            (save / "map" / "1" / "3.bin").write_bytes(broken)
            report_path = root / "report.json"
            result = audit_chunks(save, "servertest", report_path)
            self.assertEqual(result["checkedChunkCount"], 2)
            self.assertEqual(result["invalidChunkCount"], 1)
            self.assertEqual((result["invalidChunks"][0]["wx"], result["invalidChunks"][0]["wy"]), (1, 3))
            self.assertEqual(json.loads(report_path.read_text(encoding="utf-8"))["invalidChunkCount"], 1)

    def test_startup_gate_baselines_then_blocks_new_damage(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            save = root / "servertest"
            chunk = save / "map" / "2" / "4.bin"
            chunk.parent.mkdir(parents=True)
            chunk.write_bytes(chunk_payload())
            checkpoint = root / "checkpoint.json"
            reports = root / "reports"
            first = startup_gate(save, "servertest", checkpoint, reports)
            self.assertTrue(first["baselineCreated"])
            broken = bytearray(chunk_payload(b"broken"))
            broken[-1] ^= 1
            chunk.write_bytes(broken)
            stat = chunk.stat()
            os.utime(chunk, (stat.st_atime, stat.st_mtime + 2))
            second = startup_gate(save, "servertest", checkpoint, reports)
            self.assertFalse(second["ok"])
            self.assertEqual(second["invalidChunkCount"], 1)

    def test_transaction_restore_and_rollback(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            data = root / "data"
            save = data / "Saves" / "Multiplayer" / "servertest"
            current = save / "map" / "10" / "20.bin"
            current.parent.mkdir(parents=True)
            current.write_bytes(chunk_payload(b"damaged-era"))
            (save / "map_meta.bin").write_bytes(b"META")
            (save / "isoregiondata").mkdir()
            (save / "isoregiondata" / "datachunk_10_20.bin").write_bytes(b"region")
            backups = data / "backups" / "period"
            backups.mkdir(parents=True)
            backup = backups / "backup_1.zip"
            with zipfile.ZipFile(backup, "w", allowZip64=True) as bundle:
                bundle.writestr("Saves/Multiplayer/servertest/map/10/20.bin", chunk_payload(b"good-era"))
            recovery = data / "recovery"
            with patch("pz_chunk_recovery.java_server_is_running", return_value=(False, [])):
                result = restore_chunks(save, data, "servertest", backup, [(10, 20)], recovery, "servertest")
            self.assertEqual(validate_chunk_bytes(current.read_bytes())["reason"], "ok")
            self.assertTrue(current.read_bytes().endswith(b"good-era"))
            self.assertFalse((save / "isoregiondata" / "datachunk_10_20.bin").exists())
            transaction = Path(result["transactionDir"])
            self.assertEqual(json.loads((transaction / TRANSACTION_MANIFEST).read_text(encoding="utf-8"))["state"], "completed")
            with patch("pz_chunk_recovery.java_server_is_running", return_value=(False, [])):
                rolled = rollback_transaction(transaction, "servertest", "servertest")
            self.assertEqual(rolled["state"], "rolled-back")
            self.assertTrue(current.read_bytes().endswith(b"damaged-era"))
            self.assertTrue((save / "isoregiondata" / "datachunk_10_20.bin").is_file())

    def test_lists_only_approved_backup_locations(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            data = root / "data"
            save = data / "Saves" / "Multiplayer" / "servertest"
            save.mkdir(parents=True)
            period = data / "backups" / "period"
            period.mkdir(parents=True)
            (period / "backup.zip").write_bytes(b"zip")
            recovery = data / "recovery"
            recovery.mkdir()
            result = enumerate_backups(data, save, recovery)
            self.assertEqual(len(result), 1)
            self.assertEqual(result[0]["source"], "period")

    def test_inspects_only_requested_backup_chunks(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            backup = root / "backup.zip"
            broken = bytearray(chunk_payload(b"broken"))
            broken[-1] ^= 1
            with zipfile.ZipFile(backup, "w", allowZip64=True) as bundle:
                bundle.writestr("Saves/Multiplayer/servertest/map/10/20.bin", chunk_payload(b"good"))
                bundle.writestr("Saves/Multiplayer/servertest/map/10/21.bin", broken)
            result = inspect_backup(backup, "servertest", [(10, 20), (10, 21), (10, 22)])
        self.assertFalse(result["ok"])
        self.assertEqual(result["chunks"][0]["reason"], "ok")
        self.assertEqual(result["chunks"][1]["reason"], "crc-mismatch")
        self.assertEqual(result["chunks"][2]["reason"], "missing")


if __name__ == "__main__":
    unittest.main()
