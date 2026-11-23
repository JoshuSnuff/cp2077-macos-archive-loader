#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 5 ]; then
    echo "usage: provenance_contract.sh validate PROVENANCE MANIFEST PACKAGE_ROOT TARGET_EVIDENCE" >&2
    echo "       provenance_contract.sh identity PROVENANCE MANIFEST PACKAGE_ROOT PREFLIGHT_JSON" >&2
    exit 2
fi

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMAND="$1"
python3 - "$SCRIPT_DIRECTORY" "$COMMAND" "$2" "$3" "$4" "$5" <<'PY'
import hashlib
import json
import os
import pathlib
import plistlib
import re
import stat
import subprocess
import sys
import shlex
from urllib.parse import urlparse


script_directory = pathlib.Path(sys.argv[1])
command = sys.argv[2]
provenance_path = pathlib.Path(sys.argv[3])
manifest_path = pathlib.Path(sys.argv[4])
package_root = pathlib.Path(sys.argv[5])
evidence_path = pathlib.Path(sys.argv[6])


class ContractError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise ContractError(message)


def reject_constant(value):
    raise ContractError(f"invalid JSON constant: {value}")


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ContractError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json(path):
    try:
        raw = path.read_bytes()
        text = raw.decode("utf-8", errors="strict")
        return json.loads(
            text,
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=reject_constant,
        )
    except ContractError:
        raise
    except Exception as error:
        raise ContractError(f"cannot read JSON: {path}") from error


def canonical_json(document):
    try:
        return json.dumps(
            document,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
    except Exception as error:
        raise ContractError("cannot canonicalize JSON") from error


def parse_raw_entitlements(raw):
    require(isinstance(raw, str), "native raw entitlements are invalid")
    raw_bytes = raw.encode("utf-8")
    try:
        parsed = json.loads(
            raw,
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=reject_constant,
        )
    except (ContractError, json.JSONDecodeError):
        try:
            parsed = plistlib.loads(raw_bytes)
        except Exception as error:
            raise ContractError("native raw entitlements are not valid JSON or plist data") from error
    require(isinstance(parsed, dict), "native raw entitlements must contain an object")
    return parsed, raw_bytes


def sha256_bytes(value):
    return hashlib.sha256(value).hexdigest()


def sha256_file(path):
    try:
        return sha256_bytes(path.read_bytes())
    except Exception as error:
        raise ContractError(f"cannot hash file: {path}") from error


def is_hash(value):
    return isinstance(value, str) and bool(re.fullmatch(r"[0-9a-f]{64}", value)) and value != "0" * 64


def is_path(value):
    return (
        isinstance(value, str)
        and value
        and not value.startswith(("/", "./"))
        and not value.endswith("/")
        and "\\" not in value
        and all(part not in ("", ".", "..") for part in value.split("/"))
        and not any(ord(char) < 32 or ord(char) == 127 for char in value)
    )


def is_nonempty_string(value):
    return isinstance(value, str) and bool(value.strip())


def invoke_manifest_contract(package_root_required=True):
    command_line = ["bash", str(script_directory / "manifest_contract.sh"), "validate", str(manifest_path)]
    if package_root_required:
        command_line.append(str(package_root))
    result = subprocess.run(command_line, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "manifest contract failed"
        raise ContractError(detail)


class JsonRangeParser:
    def __init__(self, data):
        self.data = data
        self.i = 0

    def whitespace(self):
        while self.i < len(self.data) and self.data[self.i] in b" \t\r\n":
            self.i += 1

    def value(self):
        self.whitespace()
        if self.i >= len(self.data):
            raise ContractError("unexpected end of manifest JSON")
        byte = self.data[self.i]
        if byte == 0x7B:
            return self.object()
        if byte == 0x5B:
            return self.array()
        if byte == 0x22:
            return self.string()
        start = self.i
        while self.i < len(self.data) and self.data[self.i] not in b" \t\r\n,]}":
            self.i += 1
        try:
            return {"value": json.loads(self.data[start:self.i]), "range": None}
        except Exception as error:
            raise ContractError("invalid manifest JSON primitive") from error

    def string(self):
        start = self.i
        self.i += 1
        content_start = self.i
        while self.i < len(self.data):
            if self.data[self.i] == 0x22:
                self.i += 1
                try:
                    value = json.loads(self.data[start:self.i])
                except Exception as error:
                    raise ContractError("invalid manifest JSON string") from error
                return {"value": value, "range": (content_start, self.i - 1)}
            if self.data[self.i] == 0x5C:
                self.i += 2
            else:
                self.i += 1
        raise ContractError("unterminated manifest JSON string")

    def object(self):
        self.i += 1
        result = {}
        nodes = {}
        self.whitespace()
        if self.i < len(self.data) and self.data[self.i] == 0x7D:
            self.i += 1
            return {"value": result, "nodes": nodes, "range": None}
        while True:
            self.whitespace()
            key = self.string()["value"]
            if key in result:
                raise ContractError(f"duplicate manifest JSON key: {key}")
            self.whitespace()
            if self.i >= len(self.data) or self.data[self.i] != 0x3A:
                raise ContractError("missing manifest JSON object colon")
            self.i += 1
            node = self.value()
            result[key] = node["value"]
            nodes[key] = node
            self.whitespace()
            if self.i < len(self.data) and self.data[self.i] == 0x7D:
                self.i += 1
                return {"value": result, "nodes": nodes, "range": None}
            if self.i >= len(self.data) or self.data[self.i] != 0x2C:
                raise ContractError("missing manifest JSON object comma")
            self.i += 1

    def array(self):
        self.i += 1
        values = []
        nodes = []
        self.whitespace()
        if self.i < len(self.data) and self.data[self.i] == 0x5D:
            self.i += 1
            return {"value": values, "nodes": nodes, "range": None}
        while True:
            node = self.value()
            values.append(node["value"])
            nodes.append(node)
            self.whitespace()
            if self.i < len(self.data) and self.data[self.i] == 0x5D:
                self.i += 1
                return {"value": values, "nodes": nodes, "range": None}
            if self.i >= len(self.data) or self.data[self.i] != 0x2C:
                raise ContractError("missing manifest JSON array comma")
            self.i += 1

    def document(self):
        node = self.value()
        self.whitespace()
        require(self.i == len(self.data), "trailing manifest JSON bytes")
        return node


def manifest_self_range(manifest_bytes):
    root = JsonRangeParser(manifest_bytes).document()
    managed_node = root.get("nodes", {}).get("managedFiles")
    require(managed_node and isinstance(managed_node.get("nodes"), list), "manifest managedFiles range is missing")
    matches = []
    for entry_node in managed_node["nodes"]:
        entry = entry_node.get("value")
        if not isinstance(entry, dict):
            continue
        if entry.get("packagePath") != "archive-loader/compatibility/manifest.json" or entry.get("gamePath") != "archive-loader/compatibility/manifest.json":
            continue
        hash_node = entry_node.get("nodes", {}).get("sha256")
        require(hash_node and hash_node.get("range"), "manifest self-entry hash range is missing")
        start, end = hash_node["range"]
        raw_hash = manifest_bytes[start:end]
        require(end - start == 64 and re.fullmatch(rb"[0-9a-f]{64}", raw_hash), "manifest self-entry hash range is malformed")
        require(entry.get("sha256") == raw_hash.decode("ascii"), "manifest self-entry parsed hash differs from bytes")
        matches.append((start, end, raw_hash.decode("ascii")))
    require(len(matches) == 1, "manifest must contain exactly one self-entry range")
    return matches[0]


def mask_manifest(manifest_bytes, self_hash):
    require(is_hash(self_hash), "manifest self-entry hash is malformed")
    start, end, parsed_hash = manifest_self_range(manifest_bytes)
    require(parsed_hash == self_hash, "manifest self-entry hash does not match manifest declaration")
    require(end - start == 64, "manifest self-entry must mask exactly 64 bytes")
    masked = manifest_bytes[:start] + b"0" * 64 + manifest_bytes[start + 64:]
    return masked, sha256_bytes(masked)


def expected_target_identity(manifest):
    target = manifest.get("target")
    sources = manifest.get("metadataSources")
    require(isinstance(target, dict) and isinstance(sources, dict), "manifest target evidence is missing")
    executable = target.get("executable")
    require(isinstance(executable, dict), "manifest executable target is missing")
    expected = {
        "architecture": target.get("architecture"),
        "bundleVersion": target.get("bundleVersion"),
        "distribution": target.get("distribution"),
        "executableSha256": executable.get("sha256"),
        "executableUUID": executable.get("uuid"),
        "game": target.get("game"),
        "gogBuildId": target.get("gogBuildId"),
        "metadataPaths": {
            field: sources[field]["path"]
            for field in (
                "architecture",
                "bundleVersion",
                "executableSha256",
                "executableUuid",
                "gogBuildId",
                "version",
            )
        },
        "platform": target.get("platform"),
        "version": target.get("version"),
    }
    expected["metadataPaths"]["executableUUID"] = expected["metadataPaths"].pop("executableUuid")
    require(all(is_nonempty_string(value) for key, value in expected.items() if key != "metadataPaths"), "manifest target evidence is incomplete")
    require(isinstance(expected["metadataPaths"], dict), "manifest target metadata paths are invalid")
    return expected


def validate_target_identity(provenance, manifest, evidence):
    target_identity = provenance.get("targetIdentity")
    expected = expected_target_identity(manifest)
    require(isinstance(target_identity, dict), "provenance targetIdentity must be an object")
    require(target_identity == expected, "provenance target identity does not match manifest")
    if evidence is not None:
        require(isinstance(evidence, dict) and set(evidence) == {"synthetic", "targetIdentity"}, "target evidence fields are invalid")
        require(evidence["synthetic"] is provenance["synthetic"], "target evidence synthetic marker mismatch")
        require(evidence["targetIdentity"] == target_identity, "target evidence does not match provenance")


def validate_source(source, item):
    require(isinstance(source, dict), "input source must be an object")
    require(set(source) <= {"immutable", "kind", "retrievedAt", "url", "commit"}, "input source fields are invalid")
    require(source.get("immutable") is True, "input source is not immutable")
    require(source.get("kind") in {"archive", "standalone"}, "input source kind is invalid")
    require(isinstance(source.get("retrievedAt"), str) and re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", source["retrievedAt"]), "input retrieval timestamp is invalid")
    has_url = "url" in source
    has_commit = "commit" in source
    require(has_url != has_commit, "input source requires exactly one immutable URL or commit")
    if has_url:
        parsed = urlparse(source["url"])
        require(parsed.scheme == "https" and parsed.netloc and not parsed.query and not parsed.fragment and bool(parsed.path), "input source URL is not immutable")
    if has_commit:
        require(isinstance(source["commit"], str) and bool(re.fullmatch(r"[0-9a-fA-F]{40}", source["commit"])), "input source commit is not a full commit ID")
    if source["kind"] == "archive":
        require(is_hash(item.get("archiveSha256")), "archive-backed input is missing archiveSha256")
    else:
        require(item.get("archiveSha256") is None, "standalone input must use archiveSha256 null")
        require(item.get("archiveSha256") != item.get("extractedSha256"), "standalone archiveSha256 duplicates extractedSha256")


def validate_native_evidence(package_path, item):
    native = item.get("nativeMachO")
    evidence = item.get("nativeEvidence")
    required_native_paths = {
        "archive-loader/bin/archive-loader",
        "archive-loader/red4ext/RED4ext.dylib",
        "archive-loader/red4ext/FridaGadget.dylib",
    }
    required_native = {
        "architectures",
        "codeSigningIdentity",
        "entitlements",
        "entitlementsSha256",
        "flags",
        "signatureType",
        "teamIdentifier",
        "verification",
    }
    if package_path == "archive-loader/bin/archive-loader":
        required_native.add("restrictSegment")
    if package_path in required_native_paths:
        require(native is True, f"required native input is not marked Mach-O: {package_path}")
    if native:
        require(isinstance(evidence, dict), f"native evidence is missing: {package_path}")
        require(required_native <= set(evidence), f"native evidence fields are incomplete: {package_path}")
        require(isinstance(evidence["architectures"], list) and "arm64" in evidence["architectures"], f"native arm64 evidence is missing: {package_path}")
        require(is_nonempty_string(evidence["codeSigningIdentity"]), f"native signing identity is missing: {package_path}")
        require(is_nonempty_string(evidence["teamIdentifier"]), f"native team identifier is missing: {package_path}")
        require(is_nonempty_string(evidence["signatureType"]), f"native signature type is missing: {package_path}")
        require(isinstance(evidence["flags"], list) and all(isinstance(flag, str) for flag in evidence["flags"]), f"native signing flags are invalid: {package_path}")
        require(isinstance(evidence["entitlements"], dict), f"native entitlements are invalid: {package_path}")
        require(is_hash(evidence["entitlementsSha256"]), f"native entitlement hash is invalid: {package_path}")
        if "entitlementsRaw" in evidence:
            raw_entitlements, entitlement_bytes = parse_raw_entitlements(evidence["entitlementsRaw"])
            require(
                canonical_json(raw_entitlements) == canonical_json(evidence["entitlements"]),
                f"native raw and structured entitlements disagree: {package_path}",
            )
        else:
            entitlement_bytes = canonical_json(evidence["entitlements"])
        require(evidence["entitlementsSha256"] == sha256_bytes(entitlement_bytes), f"native entitlement digest mismatch: {package_path}")
        verification = evidence["verification"]
        require(isinstance(verification, dict) and verification.get("status") == "passed", f"native verification did not pass: {package_path}")
        require(is_nonempty_string(verification.get("command")) and is_nonempty_string(verification.get("output")), f"native verification evidence is incomplete: {package_path}")
        try:
            verification_command = shlex.split(verification["command"])
        except ValueError as error:
            raise ContractError(f"native verification command is not parseable: {package_path}") from error
        require(
            verification_command
            and verification_command[0] == "codesign"
            and "--verify" in verification_command
            and "--strict" in verification_command,
            f"native verification must use codesign --verify --strict: {package_path}",
        )
        if package_path.endswith(("red4ext/RED4ext.dylib", "red4ext/FridaGadget.dylib")):
            require(evidence["entitlements"] == {}, f"dylib entitlements must be empty: {package_path}")
        if package_path == "archive-loader/bin/archive-loader":
            require(evidence["restrictSegment"] is True, "loader __RESTRICT evidence is missing")
    else:
        require(native is False, f"nativeMachO must be boolean: {package_path}")
        require(evidence is None, f"non-native input contains native evidence: {package_path}")


def validate_inputs(provenance, manifest, manifest_bytes):
    managed = manifest.get("managedFiles")
    require(isinstance(managed, list) and managed, "manifest managedFiles are missing")
    entries = {entry["packagePath"]: entry for entry in managed}
    native_paths = {
        "archive-loader/bin/archive-loader",
        "archive-loader/red4ext/RED4ext.dylib",
        "archive-loader/red4ext/FridaGadget.dylib",
    }
    require(native_paths <= set(entries), "manifest is missing a required native package path")
    inputs = provenance.get("inputs")
    require(isinstance(inputs, list) and inputs, "provenance inputs are missing")
    input_paths = []
    tuples = []
    self_entry = next(entry for entry in managed if entry["packagePath"] == entry["gamePath"] == "archive-loader/compatibility/manifest.json")
    masked_bytes, masked_hash = mask_manifest(manifest_bytes, self_entry["sha256"])
    require(masked_hash == self_entry["sha256"], "manifest self-hash is invalid")
    for index, item in enumerate(inputs):
        required = {
            "archiveListing",
            "archiveSha256",
            "extractedFilename",
            "extractedSha256",
            "extractionTool",
            "manifestSha256",
            "mode",
            "nativeEvidence",
            "nativeMachO",
            "originalFilename",
            "packagePath",
            "source",
        }
        require(isinstance(item, dict) and set(item) == required, f"provenance input {index} fields are invalid")
        package_path = item["packagePath"]
        require(is_path(package_path) and package_path in entries, f"provenance package path is not declared: {package_path}")
        require(package_path not in input_paths, f"duplicate provenance package path: {package_path}")
        input_paths.append(package_path)
        require(is_nonempty_string(item["originalFilename"]) and is_nonempty_string(item["extractedFilename"]), f"provenance filenames are missing: {package_path}")
        require(isinstance(item["archiveListing"], list) and all(is_nonempty_string(value) for value in item["archiveListing"]), f"archive listing is invalid: {package_path}")
        require(isinstance(item["extractionTool"], dict) and is_nonempty_string(item["extractionTool"].get("name")) and is_nonempty_string(item["extractionTool"].get("version")), f"extraction tool evidence is incomplete: {package_path}")
        validate_source(item["source"], item)
        require(is_hash(item["extractedSha256"]) and is_hash(item["manifestSha256"]), f"input hashes are invalid: {package_path}")
        expected_mode = "0755" if package_path in {"archive-loader/bin/archive-loader", "archive-loader/setup.command"} else "0644"
        require(item["mode"] == expected_mode, f"provenance mode is not deterministic: {package_path}")
        file_path = package_root / package_path
        require(file_path.is_file() and not file_path.is_symlink(), f"missing staged package file: {package_path}")
        actual_mode = format(stat.S_IMODE(file_path.stat().st_mode), "04o")
        require(actual_mode == expected_mode, f"staged package mode mismatch: {package_path}")
        actual_hash = sha256_file(file_path)
        require(actual_hash == item["extractedSha256"], f"extracted hash mismatch: {package_path}")
        declared_hash = entries[package_path]["sha256"]
        if package_path == "archive-loader/compatibility/manifest.json":
            require(actual_hash == sha256_bytes(manifest_bytes), "manifest extracted hash is not ordinary bytes")
            require(item["manifestSha256"] == declared_hash == masked_hash, "manifest masked hash mismatch")
        else:
            require(actual_hash == item["extractedSha256"] == item["manifestSha256"] == declared_hash, f"ordinary package hash mismatch: {package_path}")
        validate_native_evidence(package_path, item)
        tuples.append([package_path, item["manifestSha256"], item["mode"]])
    require(set(input_paths) == set(entries), "provenance does not cover every managed package path")
    return sorted(tuples), masked_hash


def validate_provenance(require_target_evidence):
    invoke_manifest_contract()
    provenance = load_json(provenance_path)
    manifest = load_json(manifest_path)
    manifest_bytes = manifest_path.read_bytes()
    require(isinstance(provenance, dict), "provenance root must be an object")
    required_top_level = {"inputs", "relatedPaths", "releaseId", "schema", "synthetic", "targetIdentity"}
    require(set(provenance) == required_top_level, "provenance top-level fields are invalid")
    require(provenance["schema"] == "archive-loader-release-provenance/v1", "unsupported provenance schema")
    require(is_nonempty_string(provenance["releaseId"]), "provenance releaseId is missing")
    require(isinstance(provenance["synthetic"], bool), "provenance synthetic marker is invalid")
    if provenance["synthetic"]:
        require(os.environ.get("ARCHIVE_LOADER_ALLOW_SYNTHETIC") == "1", "synthetic provenance requires ARCHIVE_LOADER_ALLOW_SYNTHETIC=1")
    require(isinstance(provenance["relatedPaths"], dict) and set(provenance["relatedPaths"]) == {"externalPullStaging", "recoveryRecord", "snapshot"}, "provenance related paths are invalid")
    require(all(is_nonempty_string(value) for value in provenance["relatedPaths"].values()), "provenance related paths are incomplete")
    validate_target_identity(provenance, manifest, load_json(evidence_path) if require_target_evidence else None)
    tuples, masked_hash = validate_inputs(provenance, manifest, manifest_bytes)
    return provenance, manifest, tuples, masked_hash


try:
    if command == "validate":
        validate_provenance(True)
        print("provenance contract valid")
    elif command == "identity":
        provenance, manifest, tuples, masked_hash = validate_provenance(False)
        preflight = load_json(evidence_path)
        require(isinstance(preflight, dict), "preflight input must be an object")
        identity = {
            "loaderVersion": manifest["loaderVersion"],
            "manifestSchema": manifest["schema"],
            "manifestSelfSha256": masked_hash,
            "manifestSha256": sha256_file(manifest_path),
            "packageTupleSha256": sha256_bytes(canonical_json(tuples)),
            "preflightSha256": sha256_bytes(canonical_json(preflight)),
            "provenanceSha256": sha256_bytes(canonical_json(provenance)),
        }
        print(json.dumps(identity, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
    else:
        raise ContractError(f"unknown command: {command}")
except ContractError as error:
    print(f"ERROR: {error}", file=sys.stderr)
    sys.exit(1)
PY
