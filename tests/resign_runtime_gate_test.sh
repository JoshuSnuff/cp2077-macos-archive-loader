#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPOSITORY_DIR/gamefiles/resign_for_red4ext.sh"
WORK_DIR="$(mktemp -d /private/tmp/resign-runtime-gate.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

GAME_DIR="$WORK_DIR/game"
EXECUTABLE="$GAME_DIR/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
mkdir -p "$(dirname "$EXECUTABLE")" "$GAME_DIR/Contents/Resources" "$GAME_DIR/archive-loader/compatibility"

python3 - "$GAME_DIR" <<'PY'
import hashlib
import json
import pathlib
import struct
import sys
import uuid

root = pathlib.Path(sys.argv[1])
binary = root / "Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
identifier = uuid.UUID("1dfa005c-ed12-306f-b349-67be555f2f72")
payload = bytearray(128)
struct.pack_into("<IiiIIIII", payload, 0, 0xFEEDFACF, 0x0100000C, 0, 2, 1, 24, 0, 0)
struct.pack_into("<II", payload, 32, 0x1B, 24)
payload[40:56] = identifier.bytes
binary.write_bytes(payload)

(root / "Cyberpunk2077.app/Contents/Info.plist").write_text(
    """<?xml version="1.0"?><plist><dict>
    <key>CFBundleShortVersionString</key><string>2.5.0</string>
    <key>CFBundleVersion</key><string>5814786</string>
    </dict></plist>"""
)
(root / "Contents/Resources/goggame-1423049311.info").write_text(
    json.dumps({"buildId": "60152051833789151"})
)
manifest = {
    "schema": "cp2077-compatibility/v1",
    "target": {
        "architecture": "arm64",
        "version": "2.5.0",
        "bundleVersion": "5814786",
        "gogBuildId": "60152051833789151",
        "executable": {
            "path": "Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077",
            "uuid": str(identifier),
            "sha256": hashlib.sha256(payload).hexdigest(),
        },
    },
}
(root / "archive-loader/compatibility/manifest.json").write_text(json.dumps(manifest))
PY

"$SCRIPT" --check-runtime-identity "$GAME_DIR"

python3 - "$GAME_DIR/archive-loader/compatibility/manifest.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
manifest = json.loads(path.read_text())
manifest["target"]["executable"]["sha256"] = "0" * 64
path.write_text(json.dumps(manifest))
PY

if "$SCRIPT" --check-runtime-identity "$GAME_DIR" >/dev/null 2>&1; then
    echo "ERROR: signing preflight accepted a mismatched executable" >&2
    exit 1
fi

echo "RED4ext signing runtime gate test passed"
