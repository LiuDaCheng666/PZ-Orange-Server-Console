#!/usr/bin/env python3
"""Audit or quarantine Project Zomboid B42 map chunks outside protected areas."""

from __future__ import annotations

import argparse
import csv
import json
import math
import os
import shutil
import sqlite3
import struct
import subprocess
import sys
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path
from typing import BinaryIO, Iterable


CHUNK_SQUARES = 8
CELL_CHUNKS = 32
EXPECTED_META_MAGIC = b"META"


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

    def string_utf(self) -> str:
        length = self.i16()
        if length <= 0:
            return ""
        return self.read_exact(length).decode("utf-8", errors="replace")

    def skip(self, length: int) -> None:
        self.stream.seek(length, os.SEEK_CUR)


def parse_safehouses(meta_path: Path) -> tuple[int, list[Safehouse]]:
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
                room_count = reader.i32()
                if room_count < 0:
                    raise ValueError("Negative room count in map_meta.bin")
                reader.skip(room_count * 10)

                building_count = reader.i32()
                if building_count < 0:
                    raise ValueError("Negative building count in map_meta.bin")
                reader.skip(building_count * building_record_size)

        safehouse_count = reader.i32()
        if safehouse_count < 0 or safehouse_count > 100000:
            raise ValueError(f"Implausible safehouse count: {safehouse_count}")

        safehouses: list[Safehouse] = []
        for _ in range(safehouse_count):
            x = reader.i32()
            y = reader.i32()
            w = reader.i32()
            h = reader.i32()
            owner = reader.string_utf()
            if world_version >= 216:
                reader.i32()  # hit points

            player_count = reader.i32()
            players = tuple(reader.string_utf() for _ in range(player_count))
            reader.i64()  # last visited
            title = reader.string_utf()
            location = ""
            if world_version >= 223:
                reader.i64()  # creation timestamp
                location = reader.string_utf()

            respawn_count = reader.i32()
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

    return world_version, safehouses


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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Audit or quarantine B42 map chunks outside safehouses and other protected areas."
    )
    parser.add_argument("--save-root", type=Path, required=True)
    parser.add_argument("--server-name", required=True)
    parser.add_argument("--manual-areas", type=Path)
    parser.add_argument("--safehouse-margin-chunks", type=int, default=1)
    parser.add_argument("--player-margin-chunks", type=int, default=2)
    parser.add_argument("--report-dir", type=Path)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument(
        "--confirmation",
        help="Required with --apply; must exactly match the server name.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    save_root = args.save_root.resolve()
    map_dir = save_root / "map"
    meta_path = save_root / "map_meta.bin"
    if not map_dir.is_dir() or not meta_path.is_file():
        raise FileNotFoundError(f"Not a B42 multiplayer save directory: {save_root}")

    if args.apply and args.confirmation != args.server_name:
        raise RuntimeError("--apply requires --confirmation matching --server-name")

    running, process_lines = java_server_is_running(save_root, args.server_name)
    if args.apply and running:
        raise RuntimeError("Refusing to apply while the matching Java server process is running")

    world_version, safehouses = parse_safehouses(meta_path)
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

    protected_chunks: set[tuple[int, int]] = set()
    for area in areas:
        protected_chunks.update(area_chunks(area))

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
        "protectedChunkCount": len(protected_chunks),
        "existingProtectedMapChunkCount": kept_map_chunks,
        "existingProtectedMapBytes": kept_bytes,
        "resetMapChunkCount": len(reset_chunks),
        "resetMapBytes": reset_bytes,
        "vehicleCountPreservedInDatabase": vehicles["count"],
        "vehicleChunksAmongResetChunks": vehicle_chunks_reset,
        "preservedFiles": [
            "players.db",
            "vehicles.db",
            "map_meta.bin",
            "global_mod_data.bin",
            "WorldDictionary.bin",
            "entity_data.bin",
            "chunkdata/*",
            "apop/*",
            "zpop/*",
            "metagrid/*",
            "isoregiondata/*",
        ],
    }

    (report_dir / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    (report_dir / "safehouses.json").write_text(
        json.dumps([asdict(item) for item in safehouses], ensure_ascii=False, indent=2),
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

    if args.apply:
        quarantine = save_root.parent / f"{save_root.name}-selective-reset-quarantine-{timestamp}"
        quarantine_map = quarantine / "map"
        quarantine_map.mkdir(parents=True, exist_ok=False)

        critical_backup = quarantine / "critical-files"
        critical_backup.mkdir()
        for name in (
            "players.db",
            "vehicles.db",
            "map_meta.bin",
            "global_mod_data.bin",
            "WorldDictionary.bin",
            "entity_data.bin",
        ):
            source = save_root / name
            if source.exists():
                shutil.copy2(source, critical_backup / name)

        moved = 0
        for wx, wy, source, _size in reset_chunks:
            target = quarantine_map / str(wx) / f"{wy}.bin"
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(source), str(target))
            moved += 1
        summary["quarantinePath"] = str(quarantine)
        summary["movedMapChunkCount"] = moved
        (report_dir / "summary.json").write_text(
            json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8"
        )

    print(json.dumps(summary, ensure_ascii=False, indent=2))
    print(f"Report: {report_dir}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
