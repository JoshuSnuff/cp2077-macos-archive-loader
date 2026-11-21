#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
    echo "usage: manifest_contract.sh validate|records|file-hash MANIFEST [FILE PACKAGE_PATH GAME_PATH]" >&2
    exit 2
fi

COMMAND="$1"
MANIFEST="$2"
shift 2

python3 - "$COMMAND" "$MANIFEST" "$@" <<'PY'
import hashlib
import json
import pathlib
import re
import sys

command = sys.argv[1]
manifest_path = pathlib.Path(sys.argv[2])

class ContractError(Exception):
    pass

class Parser:
    def __init__(self, data):
        self.data = data
        self.i = 0

    def whitespace(self):
        while self.i < len(self.data) and self.data[self.i] in b" \t\r\n":
            self.i += 1

    def value(self):
        self.whitespace()
        if self.i >= len(self.data):
            raise ContractError("unexpected end of JSON")
        byte = self.data[self.i]
        if byte == 0x7b:
            return self.object()
        if byte == 0x5b:
            return self.array()
        if byte == 0x22:
            return self.string()
        start = self.i
        while self.i < len(self.data) and self.data[self.i] not in b" \t\r\n,]}":
            self.i += 1
        try:
            return {"value": json.loads(self.data[start:self.i]), "range": None}
        except Exception as error:
            raise ContractError("invalid JSON primitive") from error

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
                    raise ContractError("invalid JSON string") from error
                return {"value": value, "range": (content_start, self.i - 1)}
            if self.data[self.i] == 0x5c:
                self.i += 2
            else:
                self.i += 1
        raise ContractError("unterminated JSON string")

    def object(self):
        self.i += 1
        result = {}
        nodes = {}
        self.whitespace()
        if self.i < len(self.data) and self.data[self.i] == 0x7d:
            self.i += 1
            return {"value": result, "nodes": nodes, "range": None}
        while True:
            self.whitespace()
            key = self.string()["value"]
            if key in result:
                raise ContractError(f"duplicate JSON key: {key}")
            self.whitespace()
            if self.i >= len(self.data) or self.data[self.i] != 0x3a:
                raise ContractError("missing JSON object colon")
            self.i += 1
            node = self.value()
            result[key] = node["value"]
            nodes[key] = node
            self.whitespace()
            if self.i < len(self.data) and self.data[self.i] == 0x7d:
                self.i += 1
                return {"value": result, "nodes": nodes, "range": None}
            if self.i >= len(self.data) or self.data[self.i] != 0x2c:
                raise ContractError("missing JSON object comma")
            self.i += 1

    def array(self):
        self.i += 1
        values = []
        nodes = []
        self.whitespace()
        if self.i < len(self.data) and self.data[self.i] == 0x5d:
            self.i += 1
            return {"value": values, "nodes": nodes, "range": None}
        while True:
            node = self.value()
            values.append(node["value"])
            nodes.append(node)
            self.whitespace()
            if self.i < len(self.data) and self.data[self.i] == 0x5d:
                self.i += 1
                return {"value": values, "nodes": nodes, "range": None}
            if self.i >= len(self.data) or self.data[self.i] != 0x2c:
                raise ContractError("missing JSON array comma")
            self.i += 1

    def document(self):
        node = self.value()
        self.whitespace()
        if self.i != len(self.data):
            raise ContractError("trailing JSON bytes")
        return node

def require(condition, message):
    if not condition:
        raise ContractError(message)

def is_hash(value, allow_zero=False):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) and (allow_zero or value != "0" * 64)

def valid_path(value):
    return (
        isinstance(value, str) and value and not value.startswith(("/", "./"))
        and not value.endswith("/") and "\\" not in value
        and all(part not in ("", ".", "..") for part in value.split("/"))
        and not any(ord(char) < 32 or ord(char) == 127 for char in value)
    )

def load(path):
    try:
        data = path.read_bytes()
        data.decode("utf-8", errors="strict")
    except Exception as error:
        raise ContractError(f"cannot read UTF-8 manifest: {path}") from error
    root = Parser(data).document()
    doc = root["value"]
    require(isinstance(doc, dict), "manifest root must be an object")
    require(set(doc) == {"schema", "loaderVersion", "target", "metadataSources", "managedFiles"}, "manifest top-level fields are invalid")
    require(doc["schema"] == "cp2077-compatibility/v1", "unsupported manifest schema")
    require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", doc["loaderVersion"] or ""), "invalid loaderVersion")

    target = doc["target"]
    require(isinstance(target, dict), "target must be an object")
    require(target.get("game") == "Cyberpunk 2077" and target.get("distribution") == "gog", "invalid target game/distribution")
    require(target.get("platform") == "macos" and target.get("architecture") == "arm64", "invalid target platform/architecture")
    require(target.get("version") == "2.5.0" and target.get("bundleVersion") == "5814786", "invalid target version")
    require(target.get("gogBuildId") == "60152051833789151", "invalid target GOG build ID")
    executable = target.get("executable", {})
    require(executable.get("path") == "Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077", "invalid executable path")
    require(re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", executable.get("uuid", "")), "invalid executable UUID")
    require(is_hash(executable.get("sha256")), "invalid executable hash")

    sources = doc["metadataSources"]
    expected_sources = {
        "version": {"path": "Cyberpunk2077.app/Contents/Info.plist", "key": "CFBundleShortVersionString"},
        "bundleVersion": {"path": "Cyberpunk2077.app/Contents/Info.plist", "key": "CFBundleVersion"},
        "gogBuildId": {"path": "Cyberpunk2077.app/Contents/Resources/goggame-1423049311.info", "key": "buildId"},
        "architecture": {"path": "Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077", "command": "lipo -archs"},
        "executableUuid": {"path": "Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077", "command": "otool -arch arm64 -l", "loadCommand": "LC_UUID"},
        "executableSha256": {"path": "Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077", "command": "shasum -a 256"},
    }
    require(sources == expected_sources, "metadataSources must use the authoritative Resources-only contract")

    managed = doc["managedFiles"]
    managed_nodes = root["nodes"]["managedFiles"]["nodes"]
    require(isinstance(managed, list) and managed, "managedFiles must be a non-empty array")
    package_paths = set()
    game_paths = set()
    self_ranges = []
    for index, (entry, node) in enumerate(zip(managed, managed_nodes)):
        require(isinstance(entry, dict) and set(entry) == {"packagePath", "gamePath", "sha256"}, f"managedFiles[{index}] fields are invalid")
        package_path = entry["packagePath"]
        game_path = entry["gamePath"]
        require(valid_path(package_path) and package_path.startswith("archive-loader/"), f"invalid packagePath: {package_path}")
        require(valid_path(game_path), f"invalid gamePath: {game_path}")
        require(package_path not in package_paths, f"duplicate packagePath: {package_path}")
        require(game_path not in game_paths, f"duplicate gamePath: {game_path}")
        package_paths.add(package_path)
        game_paths.add(game_path)
        require(is_hash(entry["sha256"]), f"invalid managed hash: {package_path}")
        if package_path == game_path == "archive-loader/compatibility/manifest.json":
            hash_node = node["nodes"].get("sha256")
            require(hash_node and hash_node["range"] and hash_node["range"][1] - hash_node["range"][0] == 64, "malformed manifest self-entry")
            self_ranges.append(hash_node["range"])
    require(len(self_ranges) == 1, "manifest must contain exactly one managed self-entry")
    start, end = self_ranges[0]
    masked = data[:start] + b"0" * 64 + data[end:]
    calculated = hashlib.sha256(masked).hexdigest()
    declared = data[start:end].decode()
    require(declared == calculated, f"manifest self-hash mismatch: declared {declared}, calculated {calculated}")
    return data, doc, calculated

try:
    manifest_bytes, document, self_hash = load(manifest_path)
    if command == "validate":
        pass
    elif command == "records":
        for entry in document["managedFiles"]:
            print("\t".join((entry["packagePath"], entry["gamePath"], entry["sha256"])))
    elif command == "file-hash":
        require(len(sys.argv) == 6, "file-hash requires FILE PACKAGE_PATH GAME_PATH")
        file_path = pathlib.Path(sys.argv[3])
        package_path = sys.argv[4]
        game_path = sys.argv[5]
        if package_path == game_path == "archive-loader/compatibility/manifest.json":
            file_bytes, _, masked_hash = load(file_path)
            require(file_bytes == manifest_bytes, "manifest source bytes differ from authoritative manifest")
            print(masked_hash)
        else:
            require(file_path.is_file(), f"missing source file: {file_path}")
            print(hashlib.sha256(file_path.read_bytes()).hexdigest())
    else:
        raise ContractError(f"unknown command: {command}")
except ContractError as error:
    print(f"ERROR: {error}", file=sys.stderr)
    sys.exit(1)
PY
