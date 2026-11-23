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
    "$GAME_DIR/Contents/Resources" \
    "$EVIDENCE_DIR" \
    "$STUB_DIR"

printf '#!/usr/bin/env bash\nprintf "archive-loader %s\\n"\n' "$VERSION" \
    > "$PACKAGE_ROOT/archive-loader/bin/archive-loader"
printf '#!/usr/bin/env bash\nprintf "setup\\n"\n' \
    > "$PACKAGE_ROOT/archive-loader/setup.command"
printf 'synthetic RED4ext dylib\n' > "$PACKAGE_ROOT/archive-loader/red4ext/RED4ext.dylib"
printf 'synthetic FridaGadget dylib\n' > "$PACKAGE_ROOT/archive-loader/red4ext/FridaGadget.dylib"
printf 'synthetic repository runtime\n' > "$PACKAGE_ROOT/archive-loader/red4ext/runtime.txt"
printf 'synthetic absent destination\n' > "$PACKAGE_ROOT/archive-loader/red4ext/absent.txt"
chmod +x \
    "$PACKAGE_ROOT/archive-loader/bin/archive-loader" \
    "$PACKAGE_ROOT/archive-loader/setup.command"

printf 'synthetic game executable\n' > "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
plutil -create xml1 "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string 2.5.0 \
    "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
plutil -insert CFBundleVersion -string 5814786 \
    "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
printf '{"buildId":"60152051833789151","fixture":"SYNTHETIC-NOT-PRODUCTION"}\n' \
    > "$GAME_DIR/Contents/Resources/goggame-1423049311.info"

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
native_paths = {
    "archive-loader/bin/archive-loader",
    "archive-loader/red4ext/RED4ext.dylib",
    "archive-loader/red4ext/FridaGadget.dylib",
}
executable_paths = {
    "archive-loader/bin/archive-loader",
    "archive-loader/setup.command",
}


def digest_bytes(value):
    return hashlib.sha256(value).hexdigest()


def digest(path):
    return digest_bytes(path.read_bytes())


def canonical(document):
    return json.dumps(document, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


managed = [
    {"gamePath": "archive-loader/bin/archive-loader", "packagePath": "archive-loader/bin/archive-loader", "sha256": digest(package_root / "archive-loader/bin/archive-loader")},
    {"gamePath": "archive-loader/setup.command", "packagePath": "archive-loader/setup.command", "sha256": digest(package_root / "archive-loader/setup.command")},
    {"gamePath": "archive-loader/compatibility/manifest.json", "packagePath": "archive-loader/compatibility/manifest.json", "sha256": "0" * 64},
    {"gamePath": "red4ext/RED4ext.dylib", "packagePath": "archive-loader/red4ext/RED4ext.dylib", "sha256": digest(package_root / "archive-loader/red4ext/RED4ext.dylib")},
    {"gamePath": "red4ext/FridaGadget.dylib", "packagePath": "archive-loader/red4ext/FridaGadget.dylib", "sha256": digest(package_root / "archive-loader/red4ext/FridaGadget.dylib")},
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
        "gogBuildId": {"key": "buildId", "path": "Contents/Resources/goggame-1423049311.info"},
        "version": {"key": "CFBundleShortVersionString", "path": "Cyberpunk2077.app/Contents/Info.plist"},
    },
    "schema": "cp2077-compatibility/v1",
    "target": {
        "architecture": "arm64", "bundleVersion": "5814786", "distribution": "gog",
        "executable": {"path": "Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077", "sha256": digest(executable), "uuid": "11111111-2222-3333-4444-555555555555"},
        "game": "Cyberpunk 2077", "gogBuildId": "60152051833789151", "platform": "macos", "version": "2.5.0",
    },
}
self_entry = next(entry for entry in managed if entry["packagePath"] == "archive-loader/compatibility/manifest.json")
masked = (json.dumps(manifest, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode()
self_entry["sha256"] = digest_bytes(masked)
manifest_bytes = (json.dumps(manifest, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode()
manifest_path.write_bytes(manifest_bytes)

target = manifest["target"]
target_identity = {
    "architecture": target["architecture"],
    "bundleVersion": target["bundleVersion"],
    "distribution": target["distribution"],
    "executableSha256": target["executable"]["sha256"],
    "executableUUID": target["executable"]["uuid"],
    "game": target["game"],
    "gogBuildId": target["gogBuildId"],
    "metadataPaths": {
        "architecture": manifest["metadataSources"]["architecture"]["path"],
        "bundleVersion": manifest["metadataSources"]["bundleVersion"]["path"],
        "executableSha256": manifest["metadataSources"]["executableSha256"]["path"],
        "executableUUID": manifest["metadataSources"]["executableUuid"]["path"],
        "gogBuildId": manifest["metadataSources"]["gogBuildId"]["path"],
        "version": manifest["metadataSources"]["version"]["path"],
    },
    "platform": target["platform"],
    "version": target["version"],
}

inputs = []
for entry in managed:
    package_path = entry["packagePath"]
    native = package_path in native_paths
    native_evidence = None
    if native:
        native_evidence = {
            "architectures": ["arm64"],
            "codeSigningIdentity": "SYNTHETIC-ADHOC",
            "entitlements": {},
            "entitlementsSha256": digest_bytes(canonical({})),
            "flags": ["adhoc"],
            "restrictSegment": package_path == "archive-loader/bin/archive-loader",
            "signatureType": "adhoc",
            "teamIdentifier": "SYNTHETIC",
            "verification": {
                "command": "codesign --verify --strict SYNTHETIC",
                "output": "SYNTHETIC verification output",
                "status": "passed",
            },
        }
    inputs.append({
        "archiveListing": [package_path],
        "archiveSha256": "a" * 64,
        "extractedFilename": pathlib.Path(package_path).name,
        "extractedSha256": digest(package_root / package_path),
        "extractionTool": {"name": "synthetic-fixture-generator", "version": "1"},
        "manifestSha256": entry["sha256"],
        "mode": "0755" if package_path in executable_paths else "0644",
        "nativeEvidence": native_evidence,
        "nativeMachO": native,
        "originalFilename": pathlib.Path(package_path).name + ".synthetic.tar.gz",
        "packagePath": package_path,
        "source": {
            "immutable": True,
            "kind": "archive",
            "retrievedAt": "2026-11-22T00:00:00Z",
            "url": "https://example.invalid/SYNTHETIC-NOT-PRODUCTION/commit/" + "1" * 40,
        },
    })

provenance = {
    "inputs": inputs,
    "relatedPaths": {"externalPullStaging": "SYNTHETIC-NOT-USED", "recoveryRecord": "SYNTHETIC-NOT-USED", "snapshot": "SYNTHETIC-NOT-USED"},
    "releaseId": f"archive-loader-{version}-macos-arm64-SYNTHETIC",
    "schema": "archive-loader-release-provenance/v1",
    "synthetic": True,
    "targetIdentity": target_identity,
}
(evidence_root / "provenance.json").write_text(json.dumps(provenance, indent=2, sort_keys=True) + "\n")
(evidence_root / "target-evidence.json").write_text(json.dumps({"synthetic": True, "targetIdentity": target_identity}, indent=2, sort_keys=True) + "\n")
PY
