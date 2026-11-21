#!/usr/bin/env python3
"""Generate a guarded RED4ext address database from audit and trace evidence."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
from pathlib import Path
from typing import Any, Iterable


REQUIRED_HOOKS = (
    ("CGameApplication_AddState", "4223801011"),
    ("Global_ExecuteProcess", "2203918127"),
    ("CBaseEngine_InitScripts", "2875532677"),
    ("CBaseEngine_LoadScripts", "3570081113"),
    ("ScriptValidator_Validate", "898639042"),
    ("AssertionFailed", "4285205681"),
    ("GameInstance_CollectSaveableSystems", "3230163856"),
    ("GsmState_SessionActive_ReportErrorCode", "2141394294"),
)


class GenerationError(Exception):
    """An audit or trace cannot safely produce an address database."""


def _read_json(path: Path) -> Any:
    try:
        with path.open(encoding="utf-8") as stream:
            return json.load(stream)
    except (OSError, json.JSONDecodeError) as exc:
        raise GenerationError(f"cannot read JSON {path}: {exc}") from exc


def _parse_integer(value: Any, label: str) -> int:
    if isinstance(value, bool):
        raise GenerationError(f"{label} must be an integer")
    if isinstance(value, int):
        number = value
    elif isinstance(value, str):
        text = value.strip()
        if ":" in text:
            text = text.rsplit(":", 1)[1]
        try:
            number = int(text, 0)
        except ValueError:
            try:
                number = int(text, 10)
            except ValueError as exc:
                raise GenerationError(f"{label} must be an integer") from exc
    else:
        raise GenerationError(f"{label} must be an integer")
    if number < 0:
        raise GenerationError(f"{label} must not be negative")
    return number


def _hash_text(value: Any, label: str) -> str:
    try:
        number = _parse_integer(value, label)
    except GenerationError:
        if not isinstance(value, str):
            raise
        text = value.strip()
        if not re.fullmatch(r"[0-9A-Fa-f]{8}", text):
            raise
        number = int(text, 16)
    if number > 0xFFFFFFFF:
        raise GenerationError(f"{label} is outside the 32-bit hash range")
    return str(number)


def _identity(document: dict[str, Any], label: str) -> str | None:
    metadata = document.get("metadata")
    candidates: list[Any] = [
        document.get("binary_uuid"),
        document.get("executable_uuid"),
        document.get("uuid"),
    ]
    if isinstance(metadata, dict):
        candidates.extend(
            [
                metadata.get("binary_uuid"),
                metadata.get("executable_uuid"),
                metadata.get("uuid"),
            ]
        )
    for value in candidates:
        if isinstance(value, str) and value.strip():
            return value.strip()
    raise GenerationError(f"{label} is missing a binary UUID")


def _same_identity(left: str, right: str) -> bool:
    return left.strip().casefold() == right.strip().casefold()


def _game_version(audit: dict[str, Any]) -> str:
    value = audit.get("game_version")
    if value is None and isinstance(audit.get("metadata"), dict):
        value = audit["metadata"].get("game_version")
    if not isinstance(value, str) or not value.strip():
        raise GenerationError("audit is missing game_version")
    return value.strip()


def _function_starts(audit: dict[str, Any]) -> set[int]:
    raw_starts = audit.get("function_starts")
    if isinstance(raw_starts, dict):
        raw_starts = list(raw_starts.keys())
    if not isinstance(raw_starts, list):
        raise GenerationError("audit is missing function_starts")

    starts: set[int] = set()
    for index, item in enumerate(raw_starts):
        if isinstance(item, dict):
            item = item.get("rva", item.get("offset"))
        try:
            starts.add(_parse_integer(item, f"function_starts[{index}]"))
        except GenerationError as exc:
            raise GenerationError(str(exc)) from exc
    return starts


def _hook_container(audit: dict[str, Any]) -> Any:
    for key in ("hooks", "per_hook", "candidates"):
        value = audit.get(key)
        if value is not None:
            return value
    raise GenerationError("audit is missing per-hook candidates")


def _lookup_hook(container: Any, name: str, hash_value: str) -> Any:
    if isinstance(container, dict):
        keys = (name, hash_value, f"0x{int(hash_value):08X}", f"0x{int(hash_value):x}")
        for key in keys:
            if key in container:
                return container[key]
        return None
    if isinstance(container, list):
        for item in container:
            if not isinstance(item, dict):
                continue
            item_name = item.get("name", item.get("hook"))
            item_hash = item.get("hash", item.get("hook_hash"))
            if item_name == name:
                return item
            if item_hash is not None:
                try:
                    if _hash_text(item_hash, "hook hash") == hash_value:
                        return item
                except GenerationError:
                    continue
    return None


def _candidate_list(hook: Any, name: str) -> list[dict[str, Any]]:
    if isinstance(hook, list):
        candidates = hook
    elif isinstance(hook, dict):
        candidates = hook.get("candidates")
        if candidates is None and "rva" in hook:
            candidates = [hook]
    else:
        candidates = None
    if not isinstance(candidates, list):
        raise GenerationError(f"required hook {name} has no candidates")
    if not all(isinstance(candidate, dict) for candidate in candidates):
        raise GenerationError(f"required hook {name} has a malformed candidate")
    return candidates


def _evidence(candidate: dict[str, Any]) -> bool:
    evidence = candidate.get("evidence", candidate.get("static_evidence"))
    if isinstance(evidence, str):
        return bool(evidence.strip())
    if isinstance(evidence, list):
        return any(isinstance(item, str) and item.strip() for item in evidence)
    return False


def _candidate_rva(candidate: dict[str, Any], hook_name: str, index: int) -> int:
    value = candidate.get("rva", candidate.get("offset"))
    return _parse_integer(value, f"{hook_name} candidate {index} RVA")


def _valid_candidates(
    hook: Any,
    hook_name: str,
    hook_hash: str,
    function_starts: set[int],
) -> list[tuple[dict[str, Any], int]]:
    candidates = _candidate_list(hook, hook_name)
    valid: list[tuple[dict[str, Any], int]] = []
    for index, candidate in enumerate(candidates):
        rva = _candidate_rva(candidate, hook_name, index)
        function_flag = candidate.get(
            "function_start",
            candidate.get("valid_function_start", candidate.get("is_function_start")),
        )
        if function_flag is False:
            raise GenerationError(
                f"{hook_name} candidate 0x{rva:X} is not a valid function start"
            )
        if rva not in function_starts or rva % 4 != 0:
            raise GenerationError(
                f"{hook_name} candidate 0x{rva:X} is not a valid function start"
            )
        if not _evidence(candidate):
            raise GenerationError(
                f"{hook_name} candidate 0x{rva:X} lacks static evidence"
            )
        candidate_hash = candidate.get("hash", hook.get("hash") if isinstance(hook, dict) else None)
        if candidate_hash is not None and _hash_text(candidate_hash, f"{hook_name} candidate hash") != hook_hash:
            raise GenerationError(f"{hook_name} candidate has the wrong hook hash")
        valid.append((candidate, rva))
    return valid


def _trace_records(path: Path) -> list[dict[str, Any]]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise GenerationError(f"cannot read trace {path}: {exc}") from exc
    if not text.strip():
        return []
    if text.lstrip().startswith("["):
        try:
            payload = json.loads(text)
        except json.JSONDecodeError as exc:
            raise GenerationError(f"cannot read trace {path}: {exc}") from exc
        records = payload
    else:
        records = []
        for line_number, line in enumerate(text.splitlines(), 1):
            if not line.strip():
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError as exc:
                raise GenerationError(f"trace line {line_number} is not JSON: {exc}") from exc
    if not isinstance(records, list) or not all(isinstance(record, dict) for record in records):
        raise GenerationError("trace must contain a list of JSON observations")
    return records


def _record_identity(record: dict[str, Any]) -> str | None:
    for key in ("binary_uuid", "executable_uuid", "uuid"):
        value = record.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


def _is_metadata(record: dict[str, Any]) -> bool:
    kind = record.get("type", record.get("kind"))
    return kind in {"metadata", "header"} and _record_identity(record) is not None


def _trace_observations(records: Iterable[dict[str, Any]], audit_uuid: str) -> dict[tuple[str, int], int]:
    observations: dict[tuple[str, int], int] = {}
    identities: list[str] = []
    for index, record in enumerate(records, 1):
        record_uuid = _record_identity(record)
        if record_uuid is not None:
            identities.append(record_uuid)
            if not _same_identity(record_uuid, audit_uuid):
                raise GenerationError(
                    f"trace UUID {record_uuid} does not match audit UUID {audit_uuid}"
                )
        if _is_metadata(record):
            continue

        hook_value = record.get(
            "hook",
            record.get("hook_name", record.get("name", record.get("hook_hash"))),
        )
        candidate_value = record.get("candidate_rva", record.get("rva", record.get("offset")))
        call_value = record.get("call_count", record.get("calls", record.get("count")))
        if hook_value is None or candidate_value is None or call_value is None:
            raise GenerationError(f"trace observation {index} is missing hook, RVA, or call count")
        try:
            rva = _parse_integer(candidate_value, f"trace observation {index} RVA")
            call_count = _parse_integer(call_value, f"trace observation {index} call count")
        except GenerationError as exc:
            raise GenerationError(str(exc)) from exc
        if call_count < 1:
            continue
        hook_key = str(hook_value)
        try:
            hook_key = _hash_text(hook_value, "trace hook")
        except GenerationError:
            pass
        key = (hook_key, rva)
        observations[key] = observations.get(key, 0) + call_count

    if not identities:
        raise GenerationError("trace is missing a binary UUID")
    return observations


def _hook_keys(name: str, hash_value: str) -> tuple[str, ...]:
    return (name, hash_value, f"0x{int(hash_value):08X}", f"0x{int(hash_value):x}")


def _select_records(audit: dict[str, Any], trace: dict[tuple[str, int], int]) -> list[dict[str, str]]:
    function_starts = _function_starts(audit)
    container = _hook_container(audit)
    records: list[dict[str, str]] = []
    for name, hash_value in REQUIRED_HOOKS:
        hook = _lookup_hook(container, name, hash_value)
        if hook is None:
            raise GenerationError(f"required hook {name} is missing")
        valid = _valid_candidates(hook, name, hash_value, function_starts)
        observed = [
            (candidate, rva)
            for candidate, rva in valid
            if any((key, rva) in trace for key in _hook_keys(name, hash_value))
        ]
        if not observed:
            raise GenerationError(f"{name} lacks runtime evidence")
        if len(observed) > 1:
            raise GenerationError(f"{name} has ambiguous runtime evidence")
        _, rva = observed[0]
        records.append({"hash": hash_value, "offset": f"1:0x{rva:X}"})
    return records


def _database(audit: dict[str, Any], addresses: list[dict[str, str]], binary_uuid: str) -> dict[str, Any]:
    return {
        "version": "1.0",
        "game_version": _game_version(audit),
        "binary_uuid": binary_uuid,
        "stats": {"total": len(addresses), "resolved": len(addresses), "unresolved": 0},
        "Addresses": addresses,
    }


def _atomic_write(path: Path, database: dict[str, Any]) -> None:
    if not path.parent.is_dir():
        raise GenerationError(f"output directory does not exist: {path.parent}")
    temporary_path: str | None = None
    try:
        file_descriptor, temporary_path = tempfile.mkstemp(
            prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
        )
        with os.fdopen(file_descriptor, "w", encoding="utf-8") as stream:
            json.dump(database, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_path, path)
        temporary_path = None
    except OSError as exc:
        raise GenerationError(f"cannot atomically write {path}: {exc}") from exc
    finally:
        if temporary_path is not None:
            try:
                os.unlink(temporary_path)
            except OSError:
                pass


def generate(audit_path: Path, trace_path: Path, output_path: Path) -> dict[str, Any]:
    audit = _read_json(audit_path)
    if not isinstance(audit, dict):
        raise GenerationError("audit must be a JSON object")
    audit_uuid = _identity(audit, "audit")
    trace_records = _trace_records(trace_path)
    trace = _trace_observations(trace_records, audit_uuid)
    addresses = _select_records(audit, trace)
    database = _database(audit, addresses, audit_uuid)
    _atomic_write(output_path, database)
    return database


def _argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("audit", type=Path, help="static analyzer JSON report")
    parser.add_argument("trace", type=Path, help="newline-delimited runtime observations")
    parser.add_argument("--output", required=True, type=Path, help="database path to replace atomically")
    parser.add_argument(
        "--require-all",
        action="store_true",
        help="require static and runtime evidence for every native hook (the safe mode)",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _argument_parser().parse_args(argv)
    try:
        generate(args.audit, args.trace, args.output)
    except GenerationError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    print(f"wrote {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
