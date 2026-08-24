#!/usr/bin/env python3
"""Audit or quarantine Project Zomboid B42 map chunks outside protected areas."""

from __future__ import annotations

import argparse
import csv
import json
import math
import os
import re
import shutil
import sqlite3
import struct
import subprocess
import sys
import time
import zipfile
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path, PurePosixPath
from typing import BinaryIO, Iterable


CHUNK_SQUARES = 8
CELL_CHUNKS = 32
EXPECTED_META_MAGIC = b"META"
FULL_BACKUP_ARCHIVE = "full-save-backup.zip"
FULL_BACKUP_MANIFEST = "full-save-backup-manifest.json"
ROLLBACK_RESULT = "rollback-result.json"
RESET_GUARD_MANIFEST = "orange-selective-reset-guard-v1.txt"
RESET_GUARD_HEADER = "PZ_SELECTIVE_RESET_GUARD_V1"
REGION_HEADER_NAME = "RegionHeader.bin"
MAX_GUARD_RECORDS = 5_000_000


@dataclass(frozen=True)
class Safehouse:
    x: int
    y: int
    w: int
    h: int
    owner: str
    title: str
    location: str
    players: tuple[str, ...]


@dataclass(frozen=True)
class LivestockZone:
    zone_id: float
    x: int
    y: int
    z: int
    w: int
    h: int
    name: str


@dataclass(frozen=True)
class AnimalStateCell:
    cell_x: int
    cell_y: int
    world_version: int
    bytes: int
    path: str


@dataclass(frozen=True)
class ProtectedArea:
    name: str
    x: int
    y: int
    w: int
    h: int
    margin_chunks: int
    source: str


class BigEndianReader:
    def __init__(self, stream: BinaryIO) -> None:
        self.stream = stream

    def read_exact(self, length: int) -> bytes:
        data = self.stream.read(length)
        if len(data) != length:
            raise EOFError(f"Unexpected end of file at offset {self.stream.tell()}")
        return data

    def i16(self) -> int:
        return struct.unpack(">h", self.read_exact(2))[0]

    def i32(self) -> int:
        return struct.unpack(">i", self.read_exact(4))[0]

    def i64(self) -> int:
        return struct.unpack(">q", self.read_exact(8))[0]

    def f64(self) -> float:
        return struct.unpack(">d", self.read_exact(8))[0]

    def u8(self) -> int:
        return self.read_exact(1)[0]

    def string_utf(self) -> str:
        length = self.i16()
        if length <= 0:
            return ""
        return self.read_exact(length).decode("utf-8", errors="replace")

    def skip(self, length: int) -> None:
        self.stream.seek(length, os.SEEK_CUR)


def checked_count(value: int, label: str, maximum: int = 1_000_000) -> int:
    if value < 0 or value > maximum:
        raise ValueError(f"Implausible {label}: {value}")
    return value


def parse_world_protection(meta_path: Path) -> tuple[int, list[Safehouse], list[LivestockZone]]:
    with meta_path.open("rb") as stream:
        reader = BigEndianReader(stream)
        magic = reader.read_exact(4)
        if magic != EXPECTED_META_MAGIC:
            raise ValueError(f"Invalid map_meta.bin magic: {magic!r}")

        world_version = reader.i32()
        min_x = reader.i32()
        min_y = reader.i32()
        max_x = reader.i32()
        max_y = reader.i32()
        if max_x < min_x or max_y < min_y:
            raise ValueError("Invalid map_meta.bin cell bounds")

        building_record_size = 23 if world_version >= 201 else 19
        for _cell_x in range(min_x, max_x + 1):
            for _cell_y in range(min_y, max_y + 1):
                room_count = checked_count(reader.i32(), "room count")
                reader.skip(room_count * 10)

                building_count = checked_count(reader.i32(), "building count")
                reader.skip(building_count * building_record_size)

        safehouse_count = checked_count(reader.i32(), "safehouse count", 100_000)

        safehouses: list[Safehouse] = []
        for _ in range(safehouse_count):
            x = reader.i32()
            y = reader.i32()
            w = reader.i32()
            h = reader.i32()
            owner = reader.string_utf()
            if world_version >= 216:
                reader.i32()  # hit points

            player_count = checked_count(reader.i32(), "safehouse player count", 100_000)
            players = tuple(reader.string_utf() for _ in range(player_count))
            reader.i64()  # last visited
            title = reader.string_utf()
            location = ""
            if world_version >= 223:
                reader.i64()  # creation timestamp
                location = reader.string_utf()

            respawn_count = checked_count(reader.i32(), "safehouse respawn count", 100_000)
            for _ in range(respawn_count):
                reader.string_utf()

            safehouses.append(
                Safehouse(
                    x=x,
                    y=y,
                    w=w,
                    h=h,
                    owner=owner,
                    title=title,
                    location=location,
                    players=players,
                )
            )

        non_pvp_count = checked_count(reader.i32(), "non-PVP zone count", 100_000)
        for _ in range(non_pvp_count):
            reader.skip(20)  # x, y, x2, y2, size
            reader.string_utf()

        faction_count = checked_count(reader.i32(), "faction count", 100_000)
        for _ in range(faction_count):
            reader.string_utf()  # name
            reader.string_utf()  # owner
            player_count = checked_count(reader.i32(), "faction player count", 100_000)
            if reader.u8() != 0:
                reader.string_utf()  # tag
                reader.skip(12)  # RGB floats
            for _ in range(player_count):
                reader.string_utf()

        designation_count = checked_count(reader.i32(), "designation zone count", 1_000_000)
        livestock_zones: list[LivestockZone] = []
        for _ in range(designation_count):
            zone_id = reader.f64()
            x = reader.i32()
            y = reader.i32()
            z = reader.i32()
            h = reader.i32()
            w = reader.i32()
            zone_type = reader.string_utf()
            name = reader.string_utf()
            reader.i32()  # hour last seen
            if zone_type == "AnimalZone":
                if w <= 0 or h <= 0:
                    raise ValueError(f"AnimalZone has non-positive dimensions: {name!r}")
                livestock_zones.append(
                    LivestockZone(
                        zone_id=zone_id,
                        x=x,
                        y=y,
                        z=z,
                        w=w,
                        h=h,
                        name=name,
                    )
                )

    return world_version, safehouses, livestock_zones


APOP_FILE_PATTERN = re.compile(r"^apop_(-?\d+)_(-?\d+)\.bin$")
EMPTY_APOP_BYTES = 4 + CELL_CHUNKS * CELL_CHUNKS * 4


def read_animal_state_cells(apop_dir: Path) -> tuple[list[AnimalStateCell], list[dict]]:
    if not apop_dir.exists():
        return [], []
    if not apop_dir.is_dir():
        raise ValueError(f"Animal population path is not a directory: {apop_dir}")

    populated: list[AnimalStateCell] = []
    all_files: list[dict] = []
    for path in sorted(apop_dir.iterdir(), key=lambda item: item.name):
        if not path.is_file():
            continue
        match = APOP_FILE_PATTERN.fullmatch(path.name)
        if match is None:
            continue
        payload = path.read_bytes()
        if len(payload) < EMPTY_APOP_BYTES:
            raise ValueError(f"Animal population file is truncated: {path}")
        world_version = struct.unpack(">i", payload[:4])[0]
        if world_version < 197 or world_version > 10_000:
            raise ValueError(f"Unsupported animal population version {world_version}: {path}")
        has_state = any(payload[4:])
        record = {
            "cellX": int(match.group(1)),
            "cellY": int(match.group(2)),
            "worldVersion": world_version,
            "bytes": len(payload),
            "hasState": has_state,
            "path": str(path),
        }
        all_files.append(record)
        if has_state:
            populated.append(
                AnimalStateCell(
                    cell_x=record["cellX"],
                    cell_y=record["cellY"],
                    world_version=world_version,
                    bytes=len(payload),
                    path=str(path),
                )
            )
    return populated, all_files


def open_readonly_sqlite(path: Path) -> sqlite3.Connection:
    uri = path.resolve().as_uri() + "?mode=ro"
    connection = sqlite3.connect(uri, uri=True, timeout=10)
    connection.row_factory = sqlite3.Row
    return connection


def table_columns(connection: sqlite3.Connection, table: str) -> set[str]:
    return {str(row[1]) for row in connection.execute(f'PRAGMA table_info("{table}")')}


def read_player_areas(players_db: Path, margin_chunks: int) -> tuple[list[ProtectedArea], list[dict]]:
    if not players_db.exists():
        return [], []

    areas: list[ProtectedArea] = []
    players: list[dict] = []
    with open_readonly_sqlite(players_db) as connection:
        tables = {
            str(row[0])
            for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")
        }
        candidate = next(
            (name for name in ("networkPlayers", "localPlayers") if name in tables), None
        )
        if candidate is None:
            return [], []

        columns = table_columns(connection, candidate)
        required = {"x", "y"}
        if not required.issubset(columns):
            return [], []

        select_columns = [name for name in ("id", "username", "name", "x", "y", "z", "isDead") if name in columns]
        query = f'SELECT {", ".join(select_columns)} FROM "{candidate}"'
        for row in connection.execute(query):
            record = dict(row)
            is_dead = bool(record.get("isDead", 0))
            players.append(record)
            if is_dead:
                continue
            x = math.floor(float(record["x"]))
            y = math.floor(float(record["y"]))
            label = str(record.get("username") or record.get("name") or record.get("id") or "unknown")
            areas.append(
                ProtectedArea(
                    name=f"player:{label}",
                    x=x,
                    y=y,
                    w=1,
                    h=1,
                    margin_chunks=margin_chunks,
                    source="living-player",
                )
            )
    return areas, players


def read_vehicle_summary(vehicles_db: Path) -> dict:
    if not vehicles_db.exists():
        return {"count": 0, "chunks": set(), "rows": []}

    rows: list[dict] = []
    chunks: set[tuple[int, int]] = set()
    with open_readonly_sqlite(vehicles_db) as connection:
        tables = {
            str(row[0])
            for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")
        }
        if "vehicles" not in tables:
            return {"count": 0, "chunks": set(), "rows": []}
        for row in connection.execute("SELECT id, wx, wy, x, y, inMeta FROM vehicles"):
            record = dict(row)
            rows.append(record)
            if record.get("wx") is not None and record.get("wy") is not None:
                chunks.add((int(record["wx"]), int(record["wy"])))
    return {"count": len(rows), "chunks": chunks, "rows": rows}


def read_manual_areas(path: Path | None) -> list[ProtectedArea]:
    if path is None:
        return []
    payload = json.loads(path.read_text(encoding="utf-8"))
    raw_areas = payload.get("protectAreas", payload) if isinstance(payload, dict) else payload
    if not isinstance(raw_areas, list):
        raise ValueError("Manual area file must contain a protectAreas array")

    areas: list[ProtectedArea] = []
    for index, raw in enumerate(raw_areas):
        areas.append(
            ProtectedArea(
                name=str(raw.get("name", f"manual:{index + 1}")),
                x=int(raw["x"]),
                y=int(raw["y"]),
                w=int(raw["w"]),
                h=int(raw["h"]),
                margin_chunks=int(raw.get("marginChunks", 1)),
                source="manual",
            )
        )
    return areas


def chunk_floor(square: int) -> int:
    return math.floor(square / CHUNK_SQUARES)


def area_chunks(area: ProtectedArea) -> Iterable[tuple[int, int]]:
    if area.w <= 0 or area.h <= 0:
        raise ValueError(f"Protected area has non-positive dimensions: {area.name}")
    min_wx = chunk_floor(area.x) - area.margin_chunks
    min_wy = chunk_floor(area.y) - area.margin_chunks
    max_wx = chunk_floor(area.x + area.w - 1) + area.margin_chunks
    max_wy = chunk_floor(area.y + area.h - 1) + area.margin_chunks
    for wx in range(min_wx, max_wx + 1):
        for wy in range(min_wy, max_wy + 1):
            yield wx, wy


def build_livestock_protection(
    livestock_zones: Iterable[LivestockZone], margin_chunks: int
) -> tuple[list[ProtectedArea], set[tuple[int, int]]]:
    areas = [
        ProtectedArea(
            name=f"livestock:{zone.name or zone.zone_id}",
            x=zone.x,
            y=zone.y,
            w=zone.w,
            h=zone.h,
            margin_chunks=margin_chunks,
            source="livestock-zone",
        )
        for zone in livestock_zones
    ]
    chunks: set[tuple[int, int]] = set()
    for area in areas:
        chunks.update(area_chunks(area))
    return areas, chunks


def iter_map_chunks(map_dir: Path) -> Iterable[tuple[int, int, Path]]:
    for wx_dir in os.scandir(map_dir):
        if not wx_dir.is_dir(follow_symlinks=False):
            continue
        try:
            wx = int(wx_dir.name)
        except ValueError:
            continue
        for entry in os.scandir(wx_dir.path):
            if not entry.is_file(follow_symlinks=False) or not entry.name.endswith(".bin"):
                continue
            try:
                wy = int(entry.name[:-4])
            except ValueError:
                continue
            yield wx, wy, Path(entry.path)


def region_hash(wx: int, wy: int) -> int:
    value = ((((wy & 0xFFFFFFFF) << 16) & 0xFFFFFFFF) ^ (wx & 0xFFFFFFFF))
    return value - 0x100000000 if value >= 0x80000000 else value


def build_region_invalidation_chunks(
    reset_chunks: Iterable[tuple[int, int]],
) -> set[tuple[int, int]]:
    result: set[tuple[int, int]] = set()
    for wx, wy in reset_chunks:
        for offset_x in (-1, 0, 1):
            for offset_y in (-1, 0, 1):
                result.add((wx + offset_x, wy + offset_y))
    return result


def region_cache_path(save_root: Path, wx: int, wy: int) -> Path:
    return save_root / "isoregiondata" / f"datachunk_{wx}_{wy}.bin"


def read_region_header(path: Path) -> tuple[int, list[int]] | None:
    if not path.is_file():
        return None
    payload = path.read_bytes()
    if len(payload) < 8:
        raise ValueError(f"IsoRegion header is truncated: {path}")
    version, count = struct.unpack_from(">ii", payload, 0)
    if count < 0 or count > MAX_GUARD_RECORDS:
        raise ValueError(f"IsoRegion header has invalid chunk count {count}: {path}")
    expected = 8 + count * 4
    if len(payload) != expected:
        raise ValueError(
            f"IsoRegion header size mismatch: expected {expected}, got {len(payload)}"
        )
    entries = list(struct.unpack_from(f">{count}i", payload, 8)) if count else []
    return version, entries


def write_region_header(path: Path, version: int, entries: Iterable[int]) -> None:
    values = list(entries)
    temporary = path.with_suffix(path.suffix + ".tmp")
    payload = bytearray(struct.pack(">ii", version, len(values)))
    if values:
        payload.extend(struct.pack(f">{len(values)}i", *values))
    temporary.write_bytes(payload)
    os.replace(temporary, path)


def read_reset_guard_manifest(
    path: Path,
) -> tuple[set[tuple[int, int]], dict[tuple[int, int], int]]:
    if not path.is_file():
        return set(), {}
    lines = path.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0].strip() != RESET_GUARD_HEADER:
        raise ValueError(f"Unsupported reset guard manifest: {path}")
    if len(lines) - 1 > MAX_GUARD_RECORDS:
        raise ValueError(f"Reset guard manifest exceeds record limit: {path}")
    vehicle_chunks: set[tuple[int, int]] = set()
    region_epochs: dict[tuple[int, int], int] = {}
    for line_number, raw in enumerate(lines[1:], start=2):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        try:
            if fields[0] == "V" and len(fields) == 3:
                vehicle_chunks.add((int(fields[1]), int(fields[2])))
            elif fields[0] == "R" and len(fields) == 4:
                epoch = int(fields[3])
                if epoch <= 0:
                    raise ValueError("epoch must be positive")
                region_epochs[(int(fields[1]), int(fields[2]))] = epoch
            else:
                raise ValueError("unknown record")
        except ValueError as failure:
            raise ValueError(
                f"Invalid reset guard manifest record at line {line_number}: {raw!r}"
            ) from failure
    return vehicle_chunks, region_epochs


def write_reset_guard_manifest(
    path: Path,
    vehicle_chunks: Iterable[tuple[int, int]],
    region_epochs: dict[tuple[int, int], int],
) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", encoding="utf-8", newline="\n") as stream:
        stream.write(RESET_GUARD_HEADER + "\n")
        stream.write("# V=disable vanilla vehicle regeneration; R=rebuild IsoRegion after epoch-ms\n")
        for wx, wy in sorted(set(vehicle_chunks)):
            stream.write(f"V\t{wx}\t{wy}\n")
        for (wx, wy), epoch in sorted(region_epochs.items()):
            stream.write(f"R\t{wx}\t{wy}\t{epoch}\n")
    os.replace(temporary, path)


def inspect_reset_guard_plan(
    save_root: Path,
    reset_coordinates: set[tuple[int, int]],
) -> dict:
    region_chunks = build_region_invalidation_chunks(reset_coordinates)
    region_files = [
        region_cache_path(save_root, wx, wy)
        for wx, wy in sorted(region_chunks)
        if region_cache_path(save_root, wx, wy).is_file()
    ]
    header_path = save_root / "isoregiondata" / REGION_HEADER_NAME
    header = read_region_header(header_path)
    invalid_hashes = {region_hash(wx, wy) for wx, wy in region_chunks}
    retained_header_entries = None
    removed_header_entries = 0
    if header is not None:
        version, entries = header
        retained_header_entries = [entry for entry in entries if entry not in invalid_hashes]
        removed_header_entries = len(entries) - len(retained_header_entries)
    else:
        version = None
    manifest_path = save_root / RESET_GUARD_MANIFEST
    previous_vehicle_chunks, previous_region_epochs = read_reset_guard_manifest(manifest_path)
    return {
        "regionChunks": region_chunks,
        "regionFiles": region_files,
        "regionHeaderPath": header_path,
        "regionHeaderVersion": version,
        "retainedRegionHeaderEntries": retained_header_entries,
        "removedRegionHeaderEntries": removed_header_entries,
        "manifestPath": manifest_path,
        "previousVehicleChunks": previous_vehicle_chunks,
        "previousRegionEpochs": previous_region_epochs,
    }


def apply_reset_transaction(
    save_root: Path,
    quarantine: Path,
    reset_chunks: list[tuple[int, int, Path, int]],
    guard_plan: dict,
    progress_path: Path | None = None,
) -> dict:
    quarantine_map = quarantine / "map"
    quarantine_regions = quarantine / "isoregiondata"
    quarantine_map.mkdir()
    quarantine_regions.mkdir()
    moved_files: list[tuple[Path, Path]] = []
    header_path: Path = guard_plan["regionHeaderPath"]
    manifest_path: Path = guard_plan["manifestPath"]
    original_header = header_path.read_bytes() if header_path.is_file() else None
    original_manifest = manifest_path.read_bytes() if manifest_path.is_file() else None
    epoch_millis = time.time_ns() // 1_000_000
    reset_coordinates = {(wx, wy) for wx, wy, _path, _size in reset_chunks}
    vehicle_chunks = set(guard_plan["previousVehicleChunks"])
    vehicle_chunks.update(reset_coordinates)
    region_epochs = dict(guard_plan["previousRegionEpochs"])
    for coordinate in guard_plan["regionChunks"]:
        region_epochs[coordinate] = epoch_millis

    try:
        moved = 0
        last_target_parent: Path | None = None
        for wx, wy, source, _size in reset_chunks:
            target = quarantine_map / str(wx) / f"{wy}.bin"
            if target.parent != last_target_parent:
                target.parent.mkdir(parents=True, exist_ok=True)
                last_target_parent = target.parent
            if target.exists():
                raise FileExistsError(f"Reset quarantine target already exists: {target}")
            shutil.move(str(source), str(target))
            moved_files.append((source, target))
            moved += 1
            if moved % 5000 == 0 or moved == len(reset_chunks):
                write_progress(
                    progress_path,
                    "reset-move",
                    moved,
                    len(reset_chunks),
                    f"Isolated {moved} of {len(reset_chunks)} map chunks",
                )

        region_files: list[Path] = guard_plan["regionFiles"]
        for index, source in enumerate(region_files, start=1):
            target = quarantine_regions / source.name
            if target.exists():
                raise FileExistsError(f"IsoRegion quarantine target already exists: {target}")
            shutil.move(str(source), str(target))
            moved_files.append((source, target))
            if index % 5000 == 0 or index == len(region_files):
                write_progress(
                    progress_path,
                    "region-invalidate",
                    index,
                    len(region_files),
                    f"Invalidated {index} of {len(region_files)} IsoRegion caches",
                )

        if original_header is not None:
            (quarantine_regions / REGION_HEADER_NAME).write_bytes(original_header)
            write_region_header(
                header_path,
                int(guard_plan["regionHeaderVersion"]),
                guard_plan["retainedRegionHeaderEntries"],
            )
        if original_manifest is not None:
            (quarantine / f"{RESET_GUARD_MANIFEST}.before-reset").write_bytes(original_manifest)
        write_progress(progress_path, "reset-manifest", 0, 1, "Writing reset guard manifest")
        write_reset_guard_manifest(manifest_path, vehicle_chunks, region_epochs)
        write_progress(progress_path, "reset-manifest", 1, 1, "Reset guard manifest committed")
        return {
            "movedMapChunkCount": moved,
            "invalidatedRegionCacheFileCount": len(region_files),
            "invalidatedRegionChunkCount": len(guard_plan["regionChunks"]),
            "removedRegionHeaderEntryCount": int(guard_plan["removedRegionHeaderEntries"]),
            "vehicleRespawnSuppressionChunkCount": len(vehicle_chunks),
            "resetGuardManifest": str(manifest_path),
            "resetEpochMillis": epoch_millis,
        }
    except Exception:
        if original_header is None:
            header_path.unlink(missing_ok=True)
        else:
            header_path.parent.mkdir(parents=True, exist_ok=True)
            header_path.write_bytes(original_header)
        if original_manifest is None:
            manifest_path.unlink(missing_ok=True)
        else:
            manifest_path.write_bytes(original_manifest)
        for source, target in reversed(moved_files):
            if target.exists():
                source.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(target), str(source))
        raise


def java_server_is_running(save_root: Path, server_name: str) -> tuple[bool, list[str]]:
    if os.name != "nt":
        return False, []
    script = (
        "$ErrorActionPreference='SilentlyContinue'; "
        "Get-CimInstance Win32_Process -Filter \"Name='java.exe'\" | "
        "Select-Object -ExpandProperty CommandLine"
    )
    result = subprocess.run(
        ["powershell.exe", "-NoProfile", "-Command", script],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    save_text = str(save_root).lower()
    name_token = f"-servername {server_name}".lower()
    matches = []
    for line in result.stdout.splitlines():
        lowered = line.lower()
        if save_text in lowered or name_token in lowered:
            matches.append(line.strip())
    return bool(matches), matches


def write_csv(path: Path, rows: Iterable[dict], fieldnames: list[str]) -> None:
    with path.open("w", encoding="utf-8-sig", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def write_progress(
    path: Path | None,
    phase: str,
    current: int = 0,
    total: int = 0,
    message: str = "",
) -> None:
    if path is None:
        return
    payload = {
        "phase": phase,
        "current": current,
        "total": total,
        "message": message,
        "updatedAt": datetime.now().astimezone().isoformat(),
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(temporary, path)


def iter_save_files(save_root: Path) -> Iterable[Path]:
    for directory, directory_names, file_names in os.walk(save_root, followlinks=False):
        directory_names.sort()
        file_names.sort()
        base = Path(directory)
        for name in directory_names:
            candidate = base / name
            if candidate.is_symlink():
                raise ValueError(f"Save backup refuses symbolic-link directory: {candidate}")
        for name in file_names:
            candidate = base / name
            if candidate.is_symlink():
                raise ValueError(f"Save backup refuses symbolic-link file: {candidate}")
            yield candidate


def scan_save_tree(save_root: Path, progress_path: Path | None = None) -> tuple[int, int]:
    file_count = 0
    total_bytes = 0
    write_progress(progress_path, "backup-scan", message="Scanning the complete save")
    for path in iter_save_files(save_root):
        file_count += 1
        total_bytes += path.stat().st_size
        if file_count % 5000 == 0:
            write_progress(
                progress_path,
                "backup-scan",
                file_count,
                0,
                f"Scanned {file_count} save files",
            )
    return file_count, total_bytes


def validate_backup_member(info: zipfile.ZipInfo) -> PurePosixPath:
    relative = PurePosixPath(info.filename)
    if info.is_dir() or not info.filename:
        raise ValueError(f"Unexpected directory entry in full backup: {info.filename!r}")
    if relative.is_absolute() or ".." in relative.parts or not relative.parts:
        raise ValueError(f"Unsafe path in full backup: {info.filename!r}")
    if ":" in relative.parts[0] or "\\" in info.filename:
        raise ValueError(f"Unsafe Windows path in full backup: {info.filename!r}")
    return relative


def verify_full_save_backup(
    quarantine: Path, progress_path: Path | None = None
) -> dict:
    archive = quarantine / FULL_BACKUP_ARCHIVE
    manifest_path = quarantine / FULL_BACKUP_MANIFEST
    if not archive.is_file() or not manifest_path.is_file():
        raise FileNotFoundError(f"Complete backup is missing from quarantine: {quarantine}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    expected_count = int(manifest["fileCount"])
    expected_bytes = int(manifest["sourceBytes"])
    verified_count = 0
    verified_bytes = 0
    write_progress(progress_path, "backup-verify", 0, expected_count, "Validating every ZIP entry CRC")
    with zipfile.ZipFile(archive, "r", allowZip64=True) as bundle:
        infos = bundle.infolist()
        if len(infos) != expected_count:
            raise ValueError(
                f"Full backup entry count mismatch: expected {expected_count}, got {len(infos)}"
            )
        for info in infos:
            validate_backup_member(info)
            with bundle.open(info, "r") as stream:
                while stream.read(1024 * 1024):
                    pass
            verified_count += 1
            verified_bytes += info.file_size
            if verified_count % 1000 == 0 or verified_count == expected_count:
                write_progress(
                    progress_path,
                    "backup-verify",
                    verified_count,
                    expected_count,
                    f"Validated {verified_count} of {expected_count} files",
                )
    if verified_bytes != expected_bytes:
        raise ValueError(
            f"Full backup byte count mismatch: expected {expected_bytes}, got {verified_bytes}"
        )
    result = dict(manifest)
    result["archivePath"] = str(archive)
    result["archiveBytes"] = archive.stat().st_size
    result["verifiedFileCount"] = verified_count
    result["verifiedBytes"] = verified_bytes
    return result


def create_full_save_backup(
    save_root: Path,
    quarantine: Path,
    server_name: str,
    progress_path: Path | None = None,
) -> dict:
    quarantine.mkdir(parents=True, exist_ok=False)
    archive = quarantine / FULL_BACKUP_ARCHIVE
    partial_archive = quarantine / f"{FULL_BACKUP_ARCHIVE}.partial"
    manifest_path = quarantine / FULL_BACKUP_MANIFEST
    file_count, source_bytes = scan_save_tree(save_root, progress_path)
    required_bytes = source_bytes + max(256 * 1024 * 1024, file_count * 512)
    free_bytes = shutil.disk_usage(quarantine.parent).free
    if free_bytes < required_bytes:
        raise OSError(
            f"Not enough free space for complete backup: required {required_bytes}, free {free_bytes}"
        )

    completed = 0
    try:
        write_progress(progress_path, "backup-write", 0, file_count, "Writing the complete save ZIP")
        with zipfile.ZipFile(
            partial_archive, "w", compression=zipfile.ZIP_STORED, allowZip64=True
        ) as bundle:
            for source in iter_save_files(save_root):
                bundle.write(source, source.relative_to(save_root).as_posix())
                completed += 1
                if completed % 1000 == 0 or completed == file_count:
                    write_progress(
                        progress_path,
                        "backup-write",
                        completed,
                        file_count,
                        f"Archived {completed} of {file_count} files",
                    )
        os.replace(partial_archive, archive)
        manifest = {
            "formatVersion": 1,
            "serverName": server_name,
            "sourceRoot": str(save_root),
            "createdAt": datetime.now().astimezone().isoformat(),
            "fileCount": file_count,
            "sourceBytes": source_bytes,
            "archiveBytes": archive.stat().st_size,
            "compression": "ZIP_STORED",
            "validation": "all-entry-crc",
        }
        manifest_path.write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        verified = verify_full_save_backup(quarantine, progress_path)
        manifest["verifiedAt"] = datetime.now().astimezone().isoformat()
        manifest["verifiedFileCount"] = verified["verifiedFileCount"]
        manifest["verifiedBytes"] = verified["verifiedBytes"]
        manifest_path.write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        return manifest
    except Exception:
        partial_archive.unlink(missing_ok=True)
        raise


def extract_full_save_backup(
    quarantine: Path, staging: Path, progress_path: Path | None = None
) -> dict:
    manifest = verify_full_save_backup(quarantine, progress_path)
    archive = quarantine / FULL_BACKUP_ARCHIVE
    required_bytes = int(manifest["sourceBytes"]) + max(
        256 * 1024 * 1024, int(manifest["fileCount"]) * 256
    )
    free_bytes = shutil.disk_usage(staging.parent).free
    if free_bytes < required_bytes:
        raise OSError(
            f"Not enough free space to stage complete rollback: required {required_bytes}, free {free_bytes}"
        )
    staging.mkdir(parents=True, exist_ok=False)
    extracted_count = 0
    extracted_bytes = 0
    last_parent: Path | None = None
    total = int(manifest["fileCount"])
    write_progress(progress_path, "rollback-extract", 0, total, "Extracting validated save backup")
    try:
        with zipfile.ZipFile(archive, "r", allowZip64=True) as bundle:
            for info in bundle.infolist():
                relative = validate_backup_member(info)
                target = staging.joinpath(*relative.parts)
                if target.parent != last_parent:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    last_parent = target.parent
                with bundle.open(info, "r") as source, target.open("wb") as destination:
                    shutil.copyfileobj(source, destination, length=1024 * 1024)
                extracted_count += 1
                extracted_bytes += info.file_size
                if extracted_count % 1000 == 0 or extracted_count == total:
                    write_progress(
                        progress_path,
                        "rollback-extract",
                        extracted_count,
                        total,
                        f"Extracted {extracted_count} of {total} files",
                    )
        if extracted_count != int(manifest["fileCount"]) or extracted_bytes != int(
            manifest["sourceBytes"]
        ):
            raise ValueError("Extracted save does not match the complete backup manifest")
        if not (staging / "map_meta.bin").is_file() or not (staging / "map").is_dir():
            raise ValueError("Extracted backup is not a valid B42 multiplayer save")
        return manifest
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def rollback_full_save(
    save_root: Path,
    quarantine: Path,
    server_name: str,
    progress_path: Path | None = None,
) -> dict:
    quarantine = quarantine.resolve()
    save_parent = save_root.parent.resolve()
    expected_prefix = f"{save_root.name}-selective-reset-quarantine-"
    if quarantine.parent != save_parent or not quarantine.name.startswith(expected_prefix):
        raise ValueError("Rollback quarantine is outside the selected save directory")
    manifest = json.loads((quarantine / FULL_BACKUP_MANIFEST).read_text(encoding="utf-8"))
    if str(manifest.get("serverName", "")) != server_name:
        raise ValueError("Rollback backup belongs to a different server")

    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    staging = save_parent / f"{save_root.name}-rollback-staging-{timestamp}"
    previous = save_parent / f"{save_root.name}-before-rollback-{timestamp}"
    manifest = extract_full_save_backup(quarantine, staging, progress_path)
    write_progress(progress_path, "rollback-swap", message="Atomically replacing the current save")
    current_moved = False
    try:
        if save_root.exists():
            save_root.rename(previous)
            current_moved = True
        staging.rename(save_root)
    except Exception:
        if current_moved and not save_root.exists() and previous.exists():
            previous.rename(save_root)
        raise

    result = {
        "mode": "rollback",
        "serverName": server_name,
        "restoredAt": datetime.now().astimezone().isoformat(),
        "saveRoot": str(save_root),
        "quarantinePath": str(quarantine),
        "restoredFromArchive": str(quarantine / FULL_BACKUP_ARCHIVE),
        "previousSavePath": str(previous) if current_moved else None,
        "restoredFileCount": int(manifest["fileCount"]),
        "restoredBytes": int(manifest["sourceBytes"]),
    }
    (quarantine / ROLLBACK_RESULT).write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    write_progress(progress_path, "completed", 1, 1, "Rollback completed")
    return result


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Audit or quarantine B42 map chunks outside safehouses and other protected areas."
    )
    parser.add_argument("--save-root", type=Path, required=True)
    parser.add_argument("--server-name", required=True)
    parser.add_argument("--manual-areas", type=Path)
    parser.add_argument("--safehouse-margin-chunks", type=int, default=1)
    parser.add_argument("--player-margin-chunks", type=int, default=2)
    parser.add_argument("--animal-margin-chunks", type=int, default=2)
    parser.add_argument("--report-dir", type=Path)
    parser.add_argument("--progress-path", type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--apply", action="store_true")
    mode.add_argument("--rollback", action="store_true")
    parser.add_argument("--quarantine", type=Path)
    parser.add_argument(
        "--confirmation",
        help="Required with --apply or --rollback; must exactly match the server name.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    save_root = args.save_root.resolve()
    if (args.apply or args.rollback) and args.confirmation != args.server_name:
        raise RuntimeError("Apply and rollback require --confirmation matching --server-name")

    running, process_lines = java_server_is_running(save_root, args.server_name)
    if (args.apply or args.rollback) and running:
        raise RuntimeError("Refusing to modify a save while the matching Java server is running")

    if args.rollback:
        if args.quarantine is None:
            raise RuntimeError("--rollback requires --quarantine")
        timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        report_dir = (
            args.report_dir
            or (save_root.parent.parent.parent / "selective-reset-reports")
        ) / f"{args.server_name}-rollback-{timestamp}"
        report_dir.mkdir(parents=True, exist_ok=False)
        result = rollback_full_save(
            save_root,
            args.quarantine,
            args.server_name,
            args.progress_path,
        )
        result["createdAt"] = datetime.now().astimezone().isoformat()
        result["serverAppearsRunning"] = running
        result["matchingProcesses"] = process_lines
        (report_dir / "summary.json").write_text(
            json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        print(json.dumps(result, ensure_ascii=False, indent=2))
        print(f"Report: {report_dir}")
        return 0

    map_dir = save_root / "map"
    meta_path = save_root / "map_meta.bin"
    if not map_dir.is_dir() or not meta_path.is_file():
        raise FileNotFoundError(f"Not a B42 multiplayer save directory: {save_root}")

    if args.animal_margin_chunks < 0 or args.animal_margin_chunks > 64:
        raise ValueError("--animal-margin-chunks must be between 0 and 64")

    world_version, safehouses, livestock_zones = parse_world_protection(meta_path)
    areas = [
        ProtectedArea(
            name=f"safehouse:{safehouse.owner or safehouse.title or index + 1}",
            x=safehouse.x,
            y=safehouse.y,
            w=safehouse.w,
            h=safehouse.h,
            margin_chunks=args.safehouse_margin_chunks,
            source="safehouse",
        )
        for index, safehouse in enumerate(safehouses)
    ]

    player_areas, players = read_player_areas(
        save_root / "players.db", args.player_margin_chunks
    )
    manual_areas = read_manual_areas(args.manual_areas)
    areas.extend(player_areas)
    areas.extend(manual_areas)

    livestock_areas, livestock_chunks = build_livestock_protection(
        livestock_zones, args.animal_margin_chunks
    )
    animal_state_cells, animal_state_files = read_animal_state_cells(save_root / "apop")

    protected_chunks: set[tuple[int, int]] = set()
    for area in areas:
        protected_chunks.update(area_chunks(area))
    protected_before_livestock = len(protected_chunks)
    areas.extend(livestock_areas)
    protected_chunks.update(livestock_chunks)
    livestock_added_protected_chunks = len(protected_chunks) - protected_before_livestock

    vehicles = read_vehicle_summary(save_root / "vehicles.db")
    reset_chunks: list[tuple[int, int, Path, int]] = []
    kept_map_chunks = 0
    kept_bytes = 0
    reset_bytes = 0
    vehicle_chunks_reset = 0
    vehicle_chunk_set = vehicles["chunks"]

    for wx, wy, path in iter_map_chunks(map_dir):
        size = path.stat().st_size
        if (wx, wy) in protected_chunks:
            kept_map_chunks += 1
            kept_bytes += size
            continue
        reset_chunks.append((wx, wy, path, size))
        reset_bytes += size
        if (wx, wy) in vehicle_chunk_set:
            vehicle_chunks_reset += 1

    reset_coordinates = {(wx, wy) for wx, wy, _path, _size in reset_chunks}
    guard_plan = inspect_reset_guard_plan(save_root, reset_coordinates)

    write_progress(
        args.progress_path,
        "audit-report",
        len(reset_chunks),
        len(reset_chunks),
        "Writing the reset audit report",
    )

    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    report_dir = (args.report_dir or (save_root.parent.parent.parent / "selective-reset-reports")) / f"{args.server_name}-{timestamp}"
    report_dir.mkdir(parents=True, exist_ok=False)

    summary = {
        "mode": "apply" if args.apply else "audit",
        "createdAt": datetime.now().astimezone().isoformat(),
        "serverName": args.server_name,
        "saveRoot": str(save_root),
        "serverAppearsRunning": running,
        "matchingProcesses": process_lines,
        "worldVersion": world_version,
        "chunkSquareSize": CHUNK_SQUARES,
        "cellChunkSize": CELL_CHUNKS,
        "safehouseCount": len(safehouses),
        "livingPlayerProtectionCount": len(player_areas),
        "manualAreaCount": len(manual_areas),
        "livestockZoneProtectionCount": len(livestock_areas),
        "livestockProtectionAddedChunkCount": livestock_added_protected_chunks,
        "animalStateCellCount": len(animal_state_cells),
        "animalMarginChunks": args.animal_margin_chunks,
        "protectedChunkCount": len(protected_chunks),
        "existingProtectedMapChunkCount": kept_map_chunks,
        "existingProtectedMapBytes": kept_bytes,
        "resetMapChunkCount": len(reset_chunks),
        "resetMapBytes": reset_bytes,
        "vehicleCountPreservedInDatabase": vehicles["count"],
        "vehicleChunksAmongResetChunks": vehicle_chunks_reset,
        "vehicleRespawnSuppressionChunkCount": len(
            set(guard_plan["previousVehicleChunks"]) | reset_coordinates
        ),
        "regionInvalidationChunkCount": len(guard_plan["regionChunks"]),
        "regionCacheFilesToInvalidate": len(guard_plan["regionFiles"]),
        "regionHeaderEntriesToRemove": int(guard_plan["removedRegionHeaderEntries"]),
        "resetGuardManifest": str(guard_plan["manifestPath"]),
        "resetGuardAgentRequired": True,
        "preservedFiles": [
            "players.db",
            "vehicles.db",
            "map_meta.bin",
            "global_mod_data.bin",
            "WorldDictionary.bin",
            "entity_data.bin",
            "map_animals.bin",
            "gos_feedingTrough.bin",
            "chunkdata/*",
            "apop/*",
            "zpop/*",
            "metagrid/*",
            "isoregiondata/* outside reset chunks and their one-chunk region halo",
        ],
    }

    quarantine = None
    if args.apply:
        quarantine = save_root.parent / f"{save_root.name}-selective-reset-quarantine-{timestamp}"
        summary["quarantinePath"] = str(quarantine)
        summary["fullSaveBackupArchive"] = str(quarantine / FULL_BACKUP_ARCHIVE)
        summary["fullSaveBackupValidated"] = False

    (report_dir / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    (report_dir / "safehouses.json").write_text(
        json.dumps([asdict(item) for item in safehouses], ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    (report_dir / "livestock-zones.json").write_text(
        json.dumps([asdict(item) for item in livestock_zones], ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    (report_dir / "protected-areas.json").write_text(
        json.dumps([asdict(item) for item in areas], ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    write_csv(
        report_dir / "reset-chunks.csv",
        (
            {"wx": wx, "wy": wy, "bytes": size, "path": str(path)}
            for wx, wy, path, size in reset_chunks
        ),
        ["wx", "wy", "bytes", "path"],
    )
    write_csv(
        report_dir / "players.csv",
        players,
        ["id", "username", "name", "x", "y", "z", "isDead"],
    )
    write_csv(
        report_dir / "vehicles.csv",
        vehicles["rows"],
        ["id", "wx", "wy", "x", "y", "inMeta"],
    )
    write_csv(
        report_dir / "animal-state-cells.csv",
        animal_state_files,
        ["cellX", "cellY", "worldVersion", "bytes", "hasState", "path"],
    )

    if args.apply and quarantine is not None:
        backup_manifest = create_full_save_backup(
            save_root,
            quarantine,
            args.server_name,
            args.progress_path,
        )
        summary["fullSaveBackupValidated"] = True
        summary["fullSaveBackupFileCount"] = int(backup_manifest["fileCount"])
        summary["fullSaveBackupSourceBytes"] = int(backup_manifest["sourceBytes"])
        summary["fullSaveBackupBytes"] = int(backup_manifest["archiveBytes"])
        summary["fullSaveBackupVerifiedAt"] = backup_manifest["verifiedAt"]
        (report_dir / "summary.json").write_text(
            json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8"
        )

        critical_backup = quarantine / "critical-files"
        critical_backup.mkdir()
        for name in (
            "players.db",
            "vehicles.db",
            "map_meta.bin",
            "global_mod_data.bin",
            "WorldDictionary.bin",
            "entity_data.bin",
            "map_animals.bin",
            "gos_feedingTrough.bin",
        ):
            source = save_root / name
            if source.exists():
                shutil.copy2(source, critical_backup / name)
        apop_source = save_root / "apop"
        if apop_source.is_dir():
            shutil.copytree(apop_source, critical_backup / "apop")

        transaction_result = apply_reset_transaction(
            save_root,
            quarantine,
            reset_chunks,
            guard_plan,
            args.progress_path,
        )
        summary.update(transaction_result)
        (report_dir / "summary.json").write_text(
            json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8"
        )

    write_progress(args.progress_path, "completed", 1, 1, "Operation completed")

    print(json.dumps(summary, ensure_ascii=False, indent=2))
    print(f"Report: {report_dir}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
