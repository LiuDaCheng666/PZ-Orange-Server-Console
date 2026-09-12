#!/usr/bin/env python3
"""Offline integrity audit and transactional recovery for PZ B42 map chunks."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import struct
import sys
import time
import zipfile
import zlib
from dataclasses import asdict
from datetime import datetime
from pathlib import Path, PurePosixPath
from typing import Iterable


TOOL_DIR = Path(__file__).resolve().parent
RESET_TOOL_DIR = TOOL_DIR.parent / "PZSelectiveWorldReset"
sys.path.insert(0, str(RESET_TOOL_DIR))

from pz_selective_world_reset import (  # noqa: E402
    REGION_HEADER_NAME,
    RESET_GUARD_MANIFEST,
    build_region_invalidation_chunks,
    create_full_save_backup,
    java_server_is_running,
    parse_world_protection,
    read_region_header,
    read_reset_guard_manifest,
    region_cache_path,
    region_hash,
    verify_full_save_backup,
    write_region_header,
    write_reset_guard_manifest,
)


FORMAT_VERSION = 1
CHUNK_HEADER_BYTES = 17
CHUNK_FILE_PATTERN = "map/{wx}/{wy}.bin"
TRANSACTION_MANIFEST = "chunk-recovery-transaction.json"
RECOVERY_BACKUP_PREFIX = "chunk-recovery-before-"
MAX_CHUNKS_PER_TRANSACTION = 1024


def now_iso() -> str:
    return datetime.now().astimezone().isoformat()


def atomic_write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    os.replace(temporary, path)


def write_progress(
    path: Path | None,
    phase: str,
    current: int = 0,
    total: int = 0,
    message: str = "",
) -> None:
    if path is None:
        return
    atomic_write_json(
        path,
        {
            "phase": phase,
            "current": current,
            "total": total,
            "message": message,
            "updatedAt": now_iso(),
        },
    )


def validate_chunk_bytes(payload: bytes) -> dict:
    result = {
        "valid": False,
        "bytes": len(payload),
        "debugFlag": None,
        "worldVersion": None,
        "declaredLength": None,
        "storedCrc": None,
        "actualCrc": None,
        "reason": "",
    }
    if len(payload) < CHUNK_HEADER_BYTES:
        result["reason"] = "truncated-header"
        return result
    result["debugFlag"] = payload[0]
    result["worldVersion"] = struct.unpack_from(">I", payload, 1)[0]
    result["declaredLength"] = struct.unpack_from(">I", payload, 5)[0]
    result["storedCrc"] = struct.unpack_from(">Q", payload, 9)[0]
    result["actualCrc"] = zlib.crc32(payload[CHUNK_HEADER_BYTES:]) & 0xFFFFFFFF
    if result["declaredLength"] != len(payload):
        result["reason"] = "length-mismatch"
    elif result["storedCrc"] != result["actualCrc"]:
        result["reason"] = "crc-mismatch"
    else:
        result["valid"] = True
        result["reason"] = "ok"
    return result


def validate_chunk_file(path: Path) -> dict:
    result = validate_chunk_bytes(path.read_bytes())
    result["path"] = str(path)
    result["modifiedAt"] = datetime.fromtimestamp(
        path.stat().st_mtime
    ).astimezone().isoformat()
    return result


def iter_map_chunks(map_dir: Path, since_epoch: float | None = None):
    if not map_dir.is_dir():
        return
    for x_entry in os.scandir(map_dir):
        if not x_entry.is_dir(follow_symlinks=False):
            continue
        try:
            wx = int(x_entry.name)
        except ValueError:
            continue
        for y_entry in os.scandir(x_entry.path):
            if not y_entry.is_file(follow_symlinks=False) or not y_entry.name.endswith(".bin"):
                continue
            try:
                wy = int(y_entry.name[:-4])
            except ValueError:
                continue
            if since_epoch is not None and y_entry.stat(follow_symlinks=False).st_mtime <= since_epoch:
                continue
            yield wx, wy, Path(y_entry.path)


def chunk_square_bounds(wx: int, wy: int) -> dict:
    return {
        "minX": wx * 8,
        "minY": wy * 8,
        "maxX": wx * 8 + 7,
        "maxY": wy * 8 + 7,
    }


def safehouse_matches(meta_path: Path, wx: int, wy: int) -> list[dict]:
    if not meta_path.is_file():
        return []
    try:
        _version, safehouses, _livestock = parse_world_protection(meta_path)
    except Exception as failure:
        return [{"parseError": str(failure)}]
    min_x, min_y = wx * 8, wy * 8
    max_x, max_y = min_x + 7, min_y + 7
    matches = []
    for item in safehouses:
        if item.x <= max_x and item.x + item.w - 1 >= min_x and item.y <= max_y and item.y + item.h - 1 >= min_y:
            matches.append(asdict(item))
    return matches


def list_safehouses(save_root: Path) -> dict:
    meta_path = save_root / "map_meta.bin"
    if not meta_path.is_file():
        raise FileNotFoundError(f"Safehouse metadata does not exist: {meta_path}")
    world_version, safehouses, _livestock = parse_world_protection(meta_path)
    records = []
    for index, item in enumerate(safehouses):
        min_wx = item.x // 8
        min_wy = item.y // 8
        max_wx = (item.x + item.w - 1) // 8
        max_wy = (item.y + item.h - 1) // 8
        chunks = [
            {"wx": wx, "wy": wy}
            for wx in range(min_wx, max_wx + 1)
            for wy in range(min_wy, max_wy + 1)
        ]
        records.append(
            {
                "id": str(index),
                "owner": item.owner,
                "title": item.title,
                "location": item.location,
                "players": list(item.players),
                "x": item.x,
                "y": item.y,
                "w": item.w,
                "h": item.h,
                "chunks": chunks,
            }
        )
    return {
        "ok": True,
        "worldVersion": world_version,
        "safehouseCount": len(records),
        "safehouses": records,
    }


def audit_chunks(
    save_root: Path,
    server_name: str,
    report_path: Path,
    since_epoch: float | None = None,
    progress_path: Path | None = None,
) -> dict:
    map_dir = save_root / "map"
    if not map_dir.is_dir():
        raise FileNotFoundError(f"Map directory does not exist: {map_dir}")
    started = time.time()
    checked = 0
    checked_bytes = 0
    invalid = []
    write_progress(progress_path, "chunk-audit", message="Scanning B42 map chunk headers and CRC")
    for wx, wy, path in iter_map_chunks(map_dir, since_epoch):
        checked += 1
        result = validate_chunk_file(path)
        checked_bytes += int(result["bytes"])
        if not result["valid"]:
            result.update(
                {
                    "wx": wx,
                    "wy": wy,
                    "squares": chunk_square_bounds(wx, wy),
                    "safehouses": safehouse_matches(save_root / "map_meta.bin", wx, wy),
                }
            )
            invalid.append(result)
        if checked % 5000 == 0:
            write_progress(progress_path, "chunk-audit", checked, 0, f"Checked {checked} chunks")
    report = {
        "formatVersion": FORMAT_VERSION,
        "mode": "audit",
        "serverName": server_name,
        "saveRoot": str(save_root),
        "createdAt": now_iso(),
        "sinceEpoch": since_epoch,
        "checkedChunkCount": checked,
        "checkedBytes": checked_bytes,
        "invalidChunkCount": len(invalid),
        "invalidChunks": invalid,
        "durationMs": int((time.time() - started) * 1000),
    }
    atomic_write_json(report_path, report)
    write_progress(progress_path, "completed", checked, checked, f"Audit complete: {len(invalid)} invalid chunks")
    return report


def read_checkpoint(path: Path) -> float | None:
    if not path.is_file():
        return None
    payload = json.loads(path.read_text(encoding="utf-8"))
    return float(payload["auditStartedEpoch"])


def startup_gate(
    save_root: Path,
    server_name: str,
    checkpoint_path: Path,
    report_root: Path,
) -> dict:
    report_root.mkdir(parents=True, exist_ok=True)
    audit_started = time.time()
    previous = read_checkpoint(checkpoint_path)
    if previous is None:
        payload = {
            "formatVersion": FORMAT_VERSION,
            "serverName": server_name,
            "auditStartedEpoch": audit_started,
            "createdAt": now_iso(),
            "mode": "baseline",
        }
        atomic_write_json(checkpoint_path, payload)
        return {"ok": True, "baselineCreated": True, "checkedChunkCount": 0, "invalidChunkCount": 0}
    report_path = report_root / f"{server_name}-startup-audit-{datetime.now().strftime('%Y%m%d-%H%M%S')}.json"
    report = audit_chunks(save_root, server_name, report_path, previous)
    if report["invalidChunkCount"]:
        report["ok"] = False
        report["reportPath"] = str(report_path)
        return report
    atomic_write_json(
        checkpoint_path,
        {
            "formatVersion": FORMAT_VERSION,
            "serverName": server_name,
            "auditStartedEpoch": audit_started,
            "updatedAt": now_iso(),
            "mode": "incremental",
            "lastCheckedChunkCount": report["checkedChunkCount"],
        },
    )
    report["ok"] = True
    report["reportPath"] = str(report_path)
    return report


def normalize_zip_member(name: str) -> PurePosixPath:
    relative = PurePosixPath(name)
    if not name or relative.is_absolute() or ".." in relative.parts or "\\" in name:
        raise ValueError(f"Unsafe ZIP member path: {name!r}")
    return relative


def find_chunk_member(bundle: zipfile.ZipFile, server_name: str, wx: int, wy: int) -> zipfile.ZipInfo:
    suffixes = (
        f"Saves/Multiplayer/{server_name}/map/{wx}/{wy}.bin",
        f"map/{wx}/{wy}.bin",
    )
    matches = []
    for info in bundle.infolist():
        normalized = normalize_zip_member(info.filename).as_posix()
        if any(normalized == suffix or normalized.endswith("/" + suffix) for suffix in suffixes):
            matches.append(info)
    if len(matches) != 1:
        raise FileNotFoundError(
            f"Expected one backup chunk map/{wx}/{wy}.bin, found {len(matches)}"
        )
    return matches[0]


def inspect_backup(backup: Path, server_name: str, chunks: Iterable[tuple[int, int]]) -> dict:
    coordinates = validate_coordinates(chunks)
    records = []
    with zipfile.ZipFile(backup, "r", allowZip64=True) as bundle:
        for wx, wy in coordinates:
            record = {
                "wx": wx,
                "wy": wy,
                "squares": chunk_square_bounds(wx, wy),
                "member": None,
                "present": False,
                "valid": False,
                "bytes": 0,
                "storedCrc": None,
                "actualCrc": None,
                "reason": "missing",
            }
            try:
                info = find_chunk_member(bundle, server_name, wx, wy)
                payload = bundle.read(info)
                validation = validate_chunk_bytes(payload)
                record.update(validation)
                record["member"] = info.filename
                record["present"] = True
            except FileNotFoundError:
                pass
            except (zipfile.BadZipFile, RuntimeError, OSError) as failure:
                record["reason"] = "zip-read-error"
                record["error"] = str(failure)
            records.append(record)
    return {
        "ok": all(item["present"] and item["valid"] for item in records),
        "backup": str(backup),
        "serverName": server_name,
        "chunkCount": len(records),
        "chunks": records,
        "checkedAt": now_iso(),
    }


def enumerate_backups(data_root: Path, save_root: Path, recovery_root: Path) -> list[dict]:
    candidates: dict[str, Path] = {}
    locations = [data_root / "backups" / "period", save_root.parent, recovery_root]
    for location in locations:
        if not location.exists():
            continue
        for pattern in ("*.zip", "*/full-save-backup.zip", "*/*/full-save-backup.zip"):
            for path in location.glob(pattern):
                if path.is_file():
                    candidates[str(path.resolve()).lower()] = path.resolve()
    period_root = (data_root / "backups" / "period").resolve()
    result = []
    for index, path in enumerate(sorted(candidates.values(), key=lambda item: item.stat().st_mtime, reverse=True)):
        stat = path.stat()
        result.append(
            {
                "id": str(index),
                "path": str(path),
                "name": path.name if path.name != "full-save-backup.zip" else path.parent.name,
                "bytes": stat.st_size,
                "modifiedAt": datetime.fromtimestamp(stat.st_mtime).astimezone().isoformat(),
                "source": "period" if path.parent == period_root else "snapshot",
            }
        )
    return result


def validate_coordinates(chunks: Iterable[tuple[int, int]]) -> list[tuple[int, int]]:
    result = sorted(set(chunks))
    if not result or len(result) > MAX_CHUNKS_PER_TRANSACTION:
        raise ValueError(f"Chunk count must be between 1 and {MAX_CHUNKS_PER_TRANSACTION}")
    for wx, wy in result:
        if abs(wx) > 10_000_000 or abs(wy) > 10_000_000:
            raise ValueError(f"Chunk coordinate out of range: {wx},{wy}")
    return result


def parse_coordinates(value: str) -> list[tuple[int, int]]:
    chunks = []
    for raw in value.replace("\n", ";").split(";"):
        raw = raw.strip()
        if not raw:
            continue
        fields = [part.strip() for part in raw.split(",")]
        if len(fields) != 2:
            raise ValueError(f"Invalid chunk coordinate: {raw!r}")
        chunks.append((int(fields[0]), int(fields[1])))
    return validate_coordinates(chunks)


def atomic_replace_bytes(target: Path, payload: bytes, require_valid_chunk: bool = True) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_name(f"{target.name}.{os.getpid()}.recovery.tmp")
    try:
        with temporary.open("wb") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        if require_valid_chunk and not validate_chunk_file(temporary)["valid"]:
            raise ValueError(f"Staged replacement failed internal CRC validation: {target}")
        os.replace(temporary, target)
    finally:
        temporary.unlink(missing_ok=True)


def capture_transaction_state(
    save_root: Path, transaction_dir: Path, chunks: list[tuple[int, int]]
) -> dict:
    transaction_dir.mkdir(parents=True, exist_ok=False)
    originals = transaction_dir / "original"
    records = []
    for wx, wy in chunks:
        source = save_root / CHUNK_FILE_PATTERN.format(wx=wx, wy=wy)
        target = originals / CHUNK_FILE_PATTERN.format(wx=wx, wy=wy)
        existed = source.is_file()
        if existed:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        records.append({"wx": wx, "wy": wy, "existed": existed, "path": str(source)})
    region_chunks = build_region_invalidation_chunks(chunks)
    region_dir = originals / "isoregiondata"
    region_files = []
    for wx, wy in sorted(region_chunks):
        source = region_cache_path(save_root, wx, wy)
        if source.is_file():
            region_dir.mkdir(parents=True, exist_ok=True)
            target = region_dir / source.name
            shutil.copy2(source, target)
            region_files.append(source.name)
    for name in (REGION_HEADER_NAME, RESET_GUARD_MANIFEST):
        source = (save_root / "isoregiondata" / name) if name == REGION_HEADER_NAME else (save_root / name)
        if source.is_file():
            target = originals / name
            shutil.copy2(source, target)
    return {"chunks": records, "regionChunks": sorted(region_chunks), "regionFiles": region_files}


def invalidate_regions(save_root: Path, chunks: list[tuple[int, int]]) -> dict:
    region_chunks = build_region_invalidation_chunks(chunks)
    deleted = 0
    for wx, wy in region_chunks:
        path = region_cache_path(save_root, wx, wy)
        if path.is_file():
            path.unlink()
            deleted += 1
    header_path = save_root / "isoregiondata" / REGION_HEADER_NAME
    header = read_region_header(header_path)
    removed = 0
    if header is not None:
        version, entries = header
        hashes = {region_hash(wx, wy) for wx, wy in region_chunks}
        retained = [entry for entry in entries if entry not in hashes]
        removed = len(entries) - len(retained)
        write_region_header(header_path, version, retained)
    manifest_path = save_root / RESET_GUARD_MANIFEST
    vehicles, _ = read_reset_guard_manifest(manifest_path)
    write_reset_guard_manifest(manifest_path, vehicles)
    return {"regionChunkCount": len(region_chunks), "deletedRegionCacheCount": deleted, "removedRegionHeaderEntries": removed}


def restore_chunks(
    save_root: Path,
    data_root: Path,
    server_name: str,
    backup_path: Path,
    chunks: list[tuple[int, int]],
    recovery_root: Path,
    confirmation: str,
    progress_path: Path | None = None,
) -> dict:
    if confirmation != server_name:
        raise RuntimeError("Confirmation must exactly match serverName")
    running, processes = java_server_is_running(save_root, server_name)
    if running:
        raise RuntimeError("Refusing to restore chunks while the matching Java server is running")
    chunks = validate_coordinates(chunks)
    backup_path = backup_path.resolve()
    allowed = {item["path"].lower() for item in enumerate_backups(data_root, save_root, recovery_root)}
    if str(backup_path).lower() not in allowed:
        raise ValueError("Backup path is outside the approved backup locations")
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    operation_root = recovery_root / f"{server_name}-chunk-recovery-{timestamp}"
    operation_root.mkdir(parents=True, exist_ok=False)
    full_snapshot = operation_root / f"{RECOVERY_BACKUP_PREFIX}{timestamp}"
    write_progress(progress_path, "full-snapshot", message="Creating and validating complete pre-recovery snapshot")
    snapshot_manifest = create_full_save_backup(save_root, full_snapshot, server_name, progress_path)
    transaction_dir = operation_root / "transaction"
    state = capture_transaction_state(save_root, transaction_dir, chunks)
    manifest = {
        "formatVersion": FORMAT_VERSION,
        "mode": "restore",
        "state": "prepared",
        "serverName": server_name,
        "saveRoot": str(save_root),
        "backupPath": str(backup_path),
        "operationRoot": str(operation_root),
        "transactionDir": str(transaction_dir),
        "createdAt": now_iso(),
        "serverAppearsRunning": running,
        "matchingProcesses": processes,
        "fullSnapshot": str(full_snapshot),
        "fullSnapshotFileCount": snapshot_manifest["fileCount"],
        **state,
    }
    atomic_write_json(transaction_dir / TRANSACTION_MANIFEST, manifest)
    replacements = []
    try:
        with zipfile.ZipFile(backup_path, "r", allowZip64=True) as bundle:
            for index, (wx, wy) in enumerate(chunks, start=1):
                info = find_chunk_member(bundle, server_name, wx, wy)
                with bundle.open(info, "r") as stream:
                    payload = stream.read()
                validation = validate_chunk_bytes(payload)
                if not validation["valid"]:
                    raise ValueError(f"Backup chunk {wx},{wy} is invalid: {validation['reason']}")
                target = save_root / CHUNK_FILE_PATTERN.format(wx=wx, wy=wy)
                atomic_replace_bytes(target, payload)
                committed = validate_chunk_file(target)
                replacements.append({"wx": wx, "wy": wy, "member": info.filename, **committed})
                write_progress(progress_path, "chunk-restore", index, len(chunks), f"Restored chunk {wx},{wy}")
        region_result = invalidate_regions(save_root, chunks)
        manifest.update({"state": "completed", "completedAt": now_iso(), "replacements": replacements, **region_result})
        atomic_write_json(transaction_dir / TRANSACTION_MANIFEST, manifest)
        write_progress(progress_path, "completed", len(chunks), len(chunks), "Chunk recovery completed")
        return manifest
    except Exception as failure:
        manifest["state"] = "failed-restoring"
        manifest["error"] = str(failure)
        atomic_write_json(transaction_dir / TRANSACTION_MANIFEST, manifest)
        rollback_transaction(transaction_dir, server_name, confirmation, check_running=False)
        raise


def rollback_transaction(
    transaction_dir: Path,
    server_name: str,
    confirmation: str,
    check_running: bool = True,
) -> dict:
    if confirmation != server_name:
        raise RuntimeError("Confirmation must exactly match serverName")
    transaction_dir = transaction_dir.resolve()
    manifest_path = transaction_dir / TRANSACTION_MANIFEST
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("serverName") != server_name:
        raise ValueError("Recovery transaction belongs to another server")
    save_root = Path(manifest["saveRoot"]).resolve()
    if check_running:
        running, _processes = java_server_is_running(save_root, server_name)
        if running:
            raise RuntimeError("Refusing to roll back chunks while the matching Java server is running")
    originals = transaction_dir / "original"
    for item in manifest["chunks"]:
        wx, wy = int(item["wx"]), int(item["wy"])
        target = save_root / CHUNK_FILE_PATTERN.format(wx=wx, wy=wy)
        source = originals / CHUNK_FILE_PATTERN.format(wx=wx, wy=wy)
        if item["existed"]:
            if not source.is_file():
                raise FileNotFoundError(f"Original transaction chunk is missing: {source}")
            atomic_replace_bytes(target, source.read_bytes(), require_valid_chunk=False)
        else:
            target.unlink(missing_ok=True)
    region_dir = save_root / "isoregiondata"
    for wx, wy in manifest["regionChunks"]:
        region_cache_path(save_root, int(wx), int(wy)).unlink(missing_ok=True)
    for name in manifest.get("regionFiles", []):
        source = originals / "isoregiondata" / name
        target = region_dir / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    header_source = originals / REGION_HEADER_NAME
    header_target = region_dir / REGION_HEADER_NAME
    if header_source.is_file():
        shutil.copy2(header_source, header_target)
    else:
        header_target.unlink(missing_ok=True)
    guard_source = originals / RESET_GUARD_MANIFEST
    guard_target = save_root / RESET_GUARD_MANIFEST
    if guard_source.is_file():
        shutil.copy2(guard_source, guard_target)
    else:
        guard_target.unlink(missing_ok=True)
    manifest.update({"state": "rolled-back", "rolledBackAt": now_iso()})
    atomic_write_json(manifest_path, manifest)
    return manifest


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="PZ B42 map chunk integrity and disaster recovery")
    subparsers = parser.add_subparsers(dest="command", required=True)

    def common(subparser):
        subparser.add_argument("--save-root", type=Path, required=True)
        subparser.add_argument("--server-name", required=True)

    audit = subparsers.add_parser("audit")
    common(audit)
    audit.add_argument("--report-path", type=Path, required=True)
    audit.add_argument("--since-epoch", type=float)
    audit.add_argument("--progress-path", type=Path)

    gate = subparsers.add_parser("startup-gate")
    common(gate)
    gate.add_argument("--checkpoint-path", type=Path, required=True)
    gate.add_argument("--report-root", type=Path, required=True)

    backups = subparsers.add_parser("list-backups")
    common(backups)
    backups.add_argument("--data-root", type=Path, required=True)
    backups.add_argument("--recovery-root", type=Path, required=True)

    safehouses = subparsers.add_parser("list-safehouses")
    common(safehouses)

    inspect = subparsers.add_parser("inspect-backup")
    inspect.add_argument("--backup", type=Path, required=True)
    inspect.add_argument("--server-name", required=True)
    inspect.add_argument("--chunks", required=True)

    restore = subparsers.add_parser("restore")
    common(restore)
    restore.add_argument("--data-root", type=Path, required=True)
    restore.add_argument("--recovery-root", type=Path, required=True)
    restore.add_argument("--backup", type=Path, required=True)
    restore.add_argument("--chunks", required=True)
    restore.add_argument("--confirmation", required=True)
    restore.add_argument("--progress-path", type=Path)

    rollback = subparsers.add_parser("rollback")
    rollback.add_argument("--transaction-dir", type=Path, required=True)
    rollback.add_argument("--server-name", required=True)
    rollback.add_argument("--confirmation", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.command == "audit":
        result = audit_chunks(args.save_root.resolve(), args.server_name, args.report_path.resolve(), args.since_epoch, args.progress_path)
    elif args.command == "startup-gate":
        result = startup_gate(args.save_root.resolve(), args.server_name, args.checkpoint_path.resolve(), args.report_root.resolve())
    elif args.command == "list-backups":
        result = {"ok": True, "backups": enumerate_backups(args.data_root.resolve(), args.save_root.resolve(), args.recovery_root.resolve())}
    elif args.command == "list-safehouses":
        result = list_safehouses(args.save_root.resolve())
    elif args.command == "inspect-backup":
        result = inspect_backup(args.backup.resolve(), args.server_name, parse_coordinates(args.chunks))
    elif args.command == "restore":
        result = restore_chunks(args.save_root.resolve(), args.data_root.resolve(), args.server_name, args.backup, parse_coordinates(args.chunks), args.recovery_root.resolve(), args.confirmation, args.progress_path)
    else:
        result = rollback_transaction(args.transaction_dir, args.server_name, args.confirmation)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    if args.command == "startup-gate" and not result.get("ok", False):
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
