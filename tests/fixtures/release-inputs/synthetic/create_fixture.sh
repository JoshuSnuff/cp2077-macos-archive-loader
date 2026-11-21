#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: create_fixture.sh DESTINATION VERSION" >&2
    exit 2
fi

DESTINATION="$1"
VERSION="$2"
PACKAGE_ROOT="$DESTINATION/package"
GAME_DIR="$DESTINATION/Cyberpunk 2077"
EVIDENCE_DIR="$DESTINATION/evidence"
STUB_DIR="$DESTINATION/stubs"

mkdir -p \
    "$PACKAGE_ROOT/archive-loader/bin" \
    "$PACKAGE_ROOT/archive-loader/compatibility" \
    "$PACKAGE_ROOT/archive-loader/red4ext" \
    "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS" \
    "$GAME_DIR/Cyberpunk2077.app/Contents/Resources" \
    "$EVIDENCE_DIR" \
    "$STUB_DIR"

printf '#!/usr/bin/env bash\nprintf "archive-loader %s\\n"\n' "$VERSION" \
    > "$PACKAGE_ROOT/archive-loader/bin/archive-loader"
printf 'synthetic repository runtime\n' > "$PACKAGE_ROOT/archive-loader/red4ext/runtime.txt"
printf 'synthetic absent destination\n' > "$PACKAGE_ROOT/archive-loader/red4ext/absent.txt"
chmod +x "$PACKAGE_ROOT/archive-loader/bin/archive-loader"

printf 'synthetic game executable\n' > "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
plutil -create xml1 "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string 2.5.0 \
    "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
plutil -insert CFBundleVersion -string 5814786 \
    "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
printf '{"buildId":"60152051833789151","fixture":"SYNTHETIC-NOT-PRODUCTION"}\n' \
    > "$GAME_DIR/Cyberpunk2077.app/Contents/Resources/goggame-1423049311.info"

cat > "$STUB_DIR/lipo" <<'EOF'
#!/usr/bin/env bash
printf 'arm64\n'
EOF
cat > "$STUB_DIR/otool" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-l" ]; then
    cat <<'OUTPUT'
Load command 0
      segname __RESTRICT
OUTPUT
else
    cat <<'OUTPUT'
      cmd LC_UUID
  cmdsize 24
     uuid 11111111-2222-3333-4444-555555555555
OUTPUT
fi
EOF
chmod +x "$STUB_DIR/lipo" "$STUB_DIR/otool"

python3 - "$PACKAGE_ROOT" "$GAME_DIR" "$VERSION" "$EVIDENCE_DIR" <<'PY'
import hashlib
import json
import pathlib
import sys

package_root = pathlib.Path(sys.argv[1])
game_root = pathlib.Path(sys.argv[2])
version = sys.argv[3]
evidence_root = pathlib.Path(sys.argv[4])
manifest_path = package_root / "archive-loader/compatibility/manifest.json"
executable = game_root / "Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

managed = [
    {"gamePath": "archive-loader/bin/archive-loader", "packagePath": "archive-loader/bin/archive-loader", "sha256": digest(package_root / "archive-loader/bin/archive-loader")},
    {"gamePath": "archive-loader/compatibility/manifest.json", "packagePath": "archive-loader/compatibility/manifest.json", "sha256": "0" * 64},
    {"gamePath": "red4ext/runtime.txt", "packagePath": "archive-loader/red4ext/runtime.txt", "sha256": digest(package_root / "archive-loader/red4ext/runtime.txt")},
    {"gamePath": "red4ext/absent.txt", "packagePath": "archive-loader/red4ext/absent.txt", "sha256": digest(package_root / "archive-loader/red4ext/absent.txt")},
]
manifest = {
    "loaderVersion": version,
    "managedFiles": managed,
    "metadataSources": {
        "architecture": {"command": "lipo -archs", "path": "Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"},
        "bundleVersion": {"key": "CFBundleVersion", "path": "Cyberpunk2077.app/Contents/Info.plist"},
        "executableSha256": {"command": "shasum -a 256", "path": "Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"},
        "executableUuid": {"command": "otool -arch arm64 -l", "loadCommand": "LC_UUID", "path": "Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"},
        "gogBuildId": {"key": "buildId", "path": "Cyberpunk2077.app/Contents/Resources/goggame-1423049311.info"},
        "version": {"key": "CFBundleShortVersionString", "path": "Cyberpunk2077.app/Contents/Info.plist"},
    },
    "schema": "cp2077-compatibility/v1",
    "target": {
        "architecture": "arm64", "bundleVersion": "5814786", "distribution": "gog",
        "executable": {"path": "Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077", "sha256": digest(executable), "uuid": "11111111-2222-3333-4444-555555555555"},
        "game": "Cyberpunk 2077", "gogBuildId": "60152051833789151", "platform": "macos", "version": "2.5.0",
    },
}
masked = (json.dumps(manifest, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode()
self_hash = hashlib.sha256(masked).hexdigest()
manifest["managedFiles"][1]["sha256"] = self_hash
manifest_bytes = (json.dumps(manifest, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode()
manifest_path.write_bytes(manifest_bytes)

inputs = []
for entry in managed:
    source = package_root / entry["packagePath"]
    inputs.append({
        "archiveListing": "SYNTHETIC fixture has no upstream archive",
        "extractedSha256": digest(source),
        "extractionTool": {"name": "synthetic-fixture-generator", "version": "1"},
        "manifestSha256": entry["sha256"],
        "nativeMachO": entry["packagePath"].endswith("/bin/archive-loader"),
        "originalArchive": {"filename": "SYNTHETIC-NOT-PRODUCTION.zip", "sha256": "a" * 64},
        "packagePath": entry["packagePath"],
        "source": {"immutable": True, "url": "https://example.invalid/SYNTHETIC-NOT-PRODUCTION/commit/1111111111111111111111111111111111111111"},
        "nativeEvidence": ({
            "architectures": ["arm64"], "codeSigningIdentity": "SYNTHETIC-NOT-SIGNED",
            "commandOutput": "SYNTHETIC otool/codesign output", "entitlementsSha256": "b" * 64,
            "teamIdentifier": "SYNTHETIC",
        } if entry["packagePath"].endswith("/bin/archive-loader") else None),
    })

provenance = {
    "inputs": inputs,
    "relatedPaths": {"externalPullStaging": "SYNTHETIC-NOT-USED", "recoveryRecord": "SYNTHETIC-NOT-USED", "snapshot": "SYNTHETIC-NOT-USED"},
    "releaseId": f"archive-loader-{version}-macos-arm64",
    "schema": "archive-loader-release-provenance/v1",
    "synthetic": True,
    "targetIdentityEvidence": {
        "executableSha256": manifest["target"]["executable"]["sha256"],
        "executableUUID": manifest["target"]["executable"]["uuid"],
        "metadataContents": "SYNTHETIC-NOT-PRODUCTION buildId=60152051833789151",
        "metadataPath": "Cyberpunk2077.app/Contents/Resources/goggame-1423049311.info",
    },
}
(evidence_root / "provenance.json").write_text(json.dumps(provenance, indent=2, sort_keys=True) + "\n")
PY
