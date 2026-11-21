#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

check_runtime_identity() {
    local game_dir="$1"
    python3 - "$game_dir" <<'PY'
import hashlib
import json
import pathlib
import plistlib
import struct
import sys
import uuid

root = pathlib.Path(sys.argv[1]).resolve()
manifest_path = root / "archive-loader/compatibility/manifest.json"
try:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    target = manifest["target"]
    expected = target["executable"]
except (OSError, KeyError, TypeError, json.JSONDecodeError) as error:
    raise SystemExit(f"ERROR: invalid runtime compatibility manifest: {error}")

if manifest.get("schema") != "cp2077-compatibility/v1":
    raise SystemExit("ERROR: unsupported runtime compatibility manifest schema")
relative_executable = expected.get("path")
if relative_executable != "Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077":
    raise SystemExit("ERROR: manifest executable path is not the tracked game executable")

executable = root / relative_executable
info_path = root / "Cyberpunk2077.app/Contents/Info.plist"
gog_path = root / "Cyberpunk2077.app/Contents/Resources/goggame-1423049311.info"
try:
    binary = executable.read_bytes()
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    gog = json.loads(gog_path.read_text(encoding="utf-8"))
except (OSError, ValueError, json.JSONDecodeError) as error:
    raise SystemExit(f"ERROR: missing or invalid runtime identity metadata: {error}")

if len(binary) < 32 or struct.unpack_from("<I", binary)[0] != 0xFEEDFACF:
    raise SystemExit("ERROR: executable is not a thin 64-bit little-endian Mach-O")
if struct.unpack_from("<i", binary, 4)[0] != 0x0100000C:
    raise SystemExit("ERROR: executable is not arm64")
ncmds, sizeofcmds = struct.unpack_from("<II", binary, 16)
if 32 + sizeofcmds > len(binary):
    raise SystemExit("ERROR: executable Mach-O load commands are truncated")
offset = 32
actual_uuid = None
for _ in range(ncmds):
    if offset + 8 > len(binary):
        raise SystemExit("ERROR: executable Mach-O load command is truncated")
    command, size = struct.unpack_from("<II", binary, offset)
    if size < 8 or offset + size > 32 + sizeofcmds:
        raise SystemExit("ERROR: executable Mach-O load command has an invalid size")
    if command == 0x1B:
        if size < 24:
            raise SystemExit("ERROR: executable LC_UUID is truncated")
        actual_uuid = str(uuid.UUID(bytes=bytes(binary[offset + 8:offset + 24])))
        break
    offset += size
if actual_uuid is None:
    raise SystemExit("ERROR: executable is missing LC_UUID")

actual = {
    "architecture": "arm64",
    "version": str(info.get("CFBundleShortVersionString", "")),
    "bundleVersion": str(info.get("CFBundleVersion", "")),
    "gogBuildId": str(gog.get("buildId", "")),
    "uuid": actual_uuid,
    "sha256": hashlib.sha256(binary).hexdigest(),
}
expected_values = {
    "architecture": str(target.get("architecture", "")),
    "version": str(target.get("version", "")),
    "bundleVersion": str(target.get("bundleVersion", "")),
    "gogBuildId": str(target.get("gogBuildId", "")),
    "uuid": str(expected.get("uuid", "")).lower(),
    "sha256": str(expected.get("sha256", "")).lower(),
}
for label, expected_value in expected_values.items():
    if not expected_value:
        raise SystemExit(f"ERROR: manifest is missing {label}")
    if actual[label] != expected_value:
        raise SystemExit(
            f"ERROR: runtime {label} mismatch: expected {expected_value}, found {actual[label]}"
        )
print("Runtime identity gate passed.")
PY
}

if [ "${1:-}" = "--check-runtime-identity" ]; then
    [ "$#" -eq 2 ] || {
        echo "Usage: $0 --check-runtime-identity GAME_DIR" >&2
        exit 64
    }
    check_runtime_identity "$2"
    exit 0
fi

[ "$#" -eq 0 ] || {
    echo "Usage: $0 [--check-runtime-identity GAME_DIR]" >&2
    exit 64
}

GAME_DIR="$SCRIPT_DIR"
APP="$GAME_DIR/Cyberpunk2077.app"
BINARY="$APP/Contents/MacOS/Cyberpunk2077"
ENT="$GAME_DIR/red4ext_entitlements.plist"

# Refuse to mutate signatures or quarantine state for an unrecognized game.
check_runtime_identity "$GAME_DIR"

echo "=== RED4ext Re-signing ==="
echo "Game: $APP"
echo ""

# 1) Nested dylibs (no entitlements)
echo "Signing nested dylibs..."
while IFS= read -r -d '' dylib; do
    codesign --force --sign - "$dylib"
done < <(find "$APP/Contents" -name "*.dylib" -print0)
echo "  done"

# 2) Frameworks (no entitlements)
echo "Signing frameworks..."
while IFS= read -r -d '' framework; do
    codesign --force --sign - "$framework"
done < <(find "$APP/Contents/Frameworks" -type d -name "*.framework" -print0)
echo "  done"

# 3) Main executable WITH entitlements
echo "Signing main executable with entitlements..."
codesign --force --sign - --entitlements "$ENT" "$BINARY"
echo "  done"

# 4) App bundle WITH entitlements
echo "Signing app bundle..."
codesign --force --sign - --entitlements "$ENT" "$APP"
echo "  done"

# 5) Remove quarantine
echo "Removing quarantine attributes..."
xattr -cr "$APP" 2>/dev/null || true
find "$GAME_DIR/red4ext" -type f -exec xattr -d com.apple.quarantine {} \; 2>/dev/null || true
echo "  done"

# Verify
echo ""
echo "=== Verification ==="
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | grep -E "flags="
codesign -d --entitlements - "$APP" 2>&1 | grep -E "allow-unsigned|allow-jit|allow-dyld|disable-library" || true
echo ""
echo "Re-signing complete."
