#!/usr/bin/env bash
# CLI lifecycle coverage for the optional native TweakXL/ArchiveXL runtime.
set -euo pipefail

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="${1:-$REPOSITORY_DIR/patcher/.build/release/archive-loader}"
FIXTURES="$REPOSITORY_DIR/tests/fixtures"
[ -x "$BINARY" ] || { echo "ERROR: no binary at $BINARY" >&2; exit 1; }

WORK_DIR="$(mktemp -d /private/tmp/archive-loader-runtime-cli-test.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT
fail() { echo "ERROR: $1" >&2; exit 1; }

cc -o "$WORK_DIR/fakegame" "$FIXTURES/fakegame.c"
cc -x c -dynamiclib -o "$WORK_DIR/runtime.dylib" - <<'C'
void archive_loader_runtime_probe(void) {}
C
codesign --force --sign - "$WORK_DIR/fakegame" >/dev/null
codesign --force --sign - "$WORK_DIR/runtime.dylib" >/dev/null

GAME_DIR="$WORK_DIR/Cyberpunk 2077"
CONTENT="$GAME_DIR/archive/Mac/content/basegame_1_engine.archive"
PACKAGE_ROOT="$WORK_DIR/runtime-package"

make_game() {
    rm -rf "$GAME_DIR"
    mkdir -p \
        "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS" \
        "$GAME_DIR/Contents/Resources" \
        "$GAME_DIR/archive/Mac/content"
    cp "$WORK_DIR/fakegame" "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
    plutil -create xml1 "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
    plutil -insert CFBundleShortVersionString -string 2.5.0 \
        "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
    plutil -insert CFBundleVersion -string 5814786 \
        "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
    printf '{"buildId":"60152051833789151"}\n' \
        > "$GAME_DIR/Contents/Resources/goggame-1423049311.info"
    printf 'vanilla-bytes' > "$CONTENT"
    "$BINARY" setup --game "$GAME_DIR" --assume-clean >/dev/null \
        || fail "setup failed for the fixture game"
}

make_runtime_package() {
    rm -rf "$PACKAGE_ROOT"
    mkdir -p \
        "$PACKAGE_ROOT/archive-loader/compatibility" \
        "$PACKAGE_ROOT/archive-loader/red4ext/plugins"
    cp "$WORK_DIR/runtime.dylib" "$PACKAGE_ROOT/archive-loader/red4ext/RED4ext.dylib"
    cp "$WORK_DIR/runtime.dylib" "$PACKAGE_ROOT/archive-loader/red4ext/plugins/TweakXL.dylib"
    cp "$WORK_DIR/runtime.dylib" "$PACKAGE_ROOT/archive-loader/red4ext/plugins/ArchiveXL.dylib"
    chmod 755 \
        "$PACKAGE_ROOT/archive-loader/red4ext/RED4ext.dylib" \
        "$PACKAGE_ROOT/archive-loader/red4ext/plugins/TweakXL.dylib" \
        "$PACKAGE_ROOT/archive-loader/red4ext/plugins/ArchiveXL.dylib"

    python3 - "$GAME_DIR" "$PACKAGE_ROOT" <<'PY'
import hashlib
import json
import pathlib
import subprocess
import sys

game = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
executable = game / "Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
uuid = next(
    line.split()[1].lower()
    for line in subprocess.check_output(
        ["otool", "-arch", "arm64", "-l", str(executable)], text=True
    ).splitlines()
    if line.strip().startswith("uuid ")
)

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

entries = [
    ("archive-loader/compatibility/manifest.json", "archive-loader/compatibility/manifest.json"),
    ("archive-loader/red4ext/RED4ext.dylib", "red4ext/RED4ext.dylib"),
    ("archive-loader/red4ext/plugins/TweakXL.dylib", "red4ext/plugins/TweakXL.dylib"),
    ("archive-loader/red4ext/plugins/ArchiveXL.dylib", "red4ext/plugins/ArchiveXL.dylib"),
]
managed = [
    {"packagePath": package, "gamePath": game_path, "sha256": "0" * 64}
    if package.endswith("manifest.json")
    else {"packagePath": package, "gamePath": game_path, "sha256": digest(root / package)}
    for package, game_path in entries
]
document = {
    "schema": "cp2077-compatibility/v1",
    "loaderVersion": "0.1.3",
    "target": {
        "game": "Cyberpunk 2077",
        "distribution": "gog",
        "platform": "macos",
        "architecture": "arm64",
        "version": "2.5.0",
        "bundleVersion": "5814786",
        "gogBuildId": "60152051833789151",
        "executable": {
            "path": "Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077",
            "uuid": uuid,
            "sha256": digest(executable),
        },
    },
    "metadataSources": {
        "version": {"path": "Cyberpunk2077.app/Contents/Info.plist", "key": "CFBundleShortVersionString"},
        "bundleVersion": {"path": "Cyberpunk2077.app/Contents/Info.plist", "key": "CFBundleVersion"},
        "gogBuildId": {"path": "Contents/Resources/goggame-1423049311.info", "key": "buildId"},
        "architecture": {"path": "Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077", "command": "lipo -archs"},
        "executableUuid": {"path": "Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077", "command": "otool -arch arm64 -l", "loadCommand": "LC_UUID"},
        "executableSha256": {"path": "Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077", "command": "shasum -a 256"},
    },
    "managedFiles": managed,
    "frameworkRuntime": {
        "schema": "archive-loader-framework-runtime/v1",
        "roles": ["red4ext-loader", "tweakxl-plugin", "archivexl-plugin"],
        "environment": {
            "DYLD_INSERT_LIBRARIES": {"mode": "prepend", "paths": ["red4ext/RED4ext.dylib"]},
            "DYLD_FORCE_FLAT_NAMESPACE": {"mode": "replace", "value": "1"},
        },
    },
}
manifest = root / "archive-loader/compatibility/manifest.json"
raw = json.dumps(document, indent=2, sort_keys=True) + "\n"
masked = hashlib.sha256(raw.encode()).hexdigest()
manifest.write_text(raw.replace("0" * 64, masked, 1))
PY
}

# Command and argv are preserved exactly after --; direct invocation without
# a command is refused before the baseline is touched.
make_game
cat > "$GAME_DIR/argv.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$#" "$1" "$2" > "$(dirname "$0")/argv.txt"
exit 0
SH
chmod +x "$GAME_DIR/argv.sh"
"$BINARY" run --no-tweaks --game "$GAME_DIR" -- ./argv.sh -- "two words" >/dev/null \
    || fail "argv fixture did not run"
[ "$(sed -n '1p' "$GAME_DIR/argv.txt")" = 2 ] || fail "argv count changed"
[ "$(sed -n '2p' "$GAME_DIR/argv.txt")" = "--" ] || fail "dash argument changed"
[ "$(sed -n '3p' "$GAME_DIR/argv.txt")" = "two words" ] || fail "spaced argument changed"
if "$BINARY" run --game "$GAME_DIR" -- >/dev/null 2>&1; then
    fail "run accepted a direct launch with no command"
fi

# A non-executable launcher is rejected before restore/archive/TweakDB writes.
printf 'sentinel-before-launcher-gate' > "$CONTENT"
printf '#!/usr/bin/env bash\nexit 0\n' > "$GAME_DIR/not-executable.sh"
chmod 644 "$GAME_DIR/not-executable.sh"
if "$BINARY" run --no-tweaks --game "$GAME_DIR" -- ./not-executable.sh >/dev/null 2>&1; then
    fail "run accepted a non-executable launcher"
fi
[ "$(cat "$CONTENT")" = "sentinel-before-launcher-gate" ] \
    || fail "launcher preflight mutated the archive"

# Requested runtime installation is explicit and removable through the same
# compatibility transaction; a malformed request cannot silently fall back.
make_runtime_package
"$BINARY" setup --runtime-package "$PACKAGE_ROOT" --game "$GAME_DIR" --assume-clean >/dev/null \
    || fail "runtime package installation failed"
[ -x "$GAME_DIR/red4ext/RED4ext.dylib" ] || fail "runtime loader was not installed"
printf 'foreign runtime file' > "$GAME_DIR/red4ext/foreign.txt"

mkdir -p "$GAME_DIR/archive-loader/mods/tweaks"
printf 'requires: [TweakXL]\nItems.Widget:\n  friendlyName: runtime\n' \
    > "$GAME_DIR/archive-loader/mods/tweaks/runtime.yaml"
cat > "$GAME_DIR/framework-launch.sh" <<'SH'
#!/usr/bin/env bash
test -n "$(find "$(dirname "$0")/r6/tweaks" -type f -print -quit 2>/dev/null)" \
    || exit 91
projection_destination="$(find "$(dirname "$0")/r6/tweaks" -type f -print -quit)"
printf '%s\n' "$projection_destination" > "$(dirname "$0")/projection-destination.txt"
cp "$projection_destination" "$(dirname "$0")/projection-copy"
cp "$(dirname "$0")/archive-loader/state/framework-projection.json" \
    "$(dirname "$0")/projection-record"
printf '%s\n' "$DYLD_INSERT_LIBRARIES" > "$(dirname "$0")/dyld.txt"
printf '%s\n' "$DYLD_FORCE_FLAT_NAMESPACE" >> "$(dirname "$0")/dyld.txt"
exec "$(dirname "$0")/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
SH
chmod +x "$GAME_DIR/framework-launch.sh"
"$BINARY" run --no-tweaks --game "$GAME_DIR" -- ./framework-launch.sh >/dev/null \
    || fail "framework run failed"
case "$(sed -n '1p' "$GAME_DIR/dyld.txt")" in
    "$GAME_DIR/red4ext/RED4ext.dylib"*) ;;
    *) fail "runtime loader was not prepended to DYLD_INSERT_LIBRARIES" ;;
esac
[ "$(sed -n '2p' "$GAME_DIR/dyld.txt")" = 1 ] || fail "replace overlay was not enforced"
[ -x "$GAME_DIR/red4ext/RED4ext.dylib" ] || fail "restore removed the permanent runtime"
[ -z "$(find "$GAME_DIR/r6/tweaks" -type f -print 2>/dev/null)" ] \
    || fail "run left a framework projection behind"

# Every installed runtime role is revalidated before a run can restore or
# project anything. A tampered role must leave the baseline untouched.
for role in \
    "red4ext/RED4ext.dylib" \
    "red4ext/plugins/TweakXL.dylib" \
    "red4ext/plugins/ArchiveXL.dylib"; do
    role_path="$GAME_DIR/$role"
    role_source="$PACKAGE_ROOT/archive-loader/$role"
    printf 'tampered runtime role' > "$role_path"
    printf 'sentinel-before-runtime-role-gate' > "$CONTENT"
    if "$BINARY" run --no-tweaks --game "$GAME_DIR" -- ./framework-launch.sh >/dev/null 2>&1; then
        fail "tampered runtime role was accepted: $role"
    fi
    [ "$(cat "$CONTENT")" = "sentinel-before-runtime-role-gate" ] \
        || fail "tampered runtime role changed the archive: $role"
    cp "$role_source" "$role_path"
done

# A stale durable projection record with a changed destination must fail
# synchronously before a run with no enabled framework projection can launch.
rm "$GAME_DIR/archive-loader/mods/tweaks/runtime.yaml"
stale_destination="$(cat "$GAME_DIR/projection-destination.txt")"
mkdir -p "$(dirname "$stale_destination")"
cp "$GAME_DIR/projection-copy" "$stale_destination"
cp "$GAME_DIR/projection-record" \
    "$GAME_DIR/archive-loader/state/framework-projection.json"
printf 'tampered projected bytes' > "$stale_destination"
cat > "$GAME_DIR/stale-projection-launch.sh" <<'SH'
#!/usr/bin/env bash
if [ -e "$(cat "$(dirname "$0")/projection-destination.txt")" ]; then
    exit 92
fi
exec "$(dirname "$0")/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
SH
chmod +x "$GAME_DIR/stale-projection-launch.sh"
printf 'sentinel-before-stale-projection-gate' > "$CONTENT"
if "$BINARY" run --no-tweaks --game "$GAME_DIR" -- ./stale-projection-launch.sh >/dev/null 2>&1; then
    fail "tampered stale projection was silently ignored"
fi
[ "$(cat "$CONTENT")" = "sentinel-before-stale-projection-gate" ] \
    || fail "stale projection gate changed the archive"

before_status="$(find "$GAME_DIR/archive-loader/state" -type f -print -exec shasum -a 256 {} \; | sort)"
status_output="$("$BINARY" status --game "$GAME_DIR" 2>&1)" \
    || fail "status rejected the clean runtime install"
printf '%s\n' "$status_output" | grep -q 'Runtime.*active' \
    || fail "status did not report the active runtime"
after_status="$(find "$GAME_DIR/archive-loader/state" -type f -print -exec shasum -a 256 {} \; | sort)"
[ "$before_status" = "$after_status" ] || fail "status mutated runtime state"

"$BINARY" runtime remove --game "$GAME_DIR" >/dev/null \
    || fail "runtime remove failed"
[ ! -e "$GAME_DIR/red4ext/RED4ext.dylib" ] || fail "runtime remove kept the loader"
[ -f "$GAME_DIR/red4ext/foreign.txt" ] || fail "runtime remove deleted an unrelated file"

# A requested real runtime is never silently downgraded to offline behavior.
make_game
make_runtime_package
rm "$PACKAGE_ROOT/archive-loader/red4ext/plugins/ArchiveXL.dylib"
printf 'sentinel-before-runtime-gate' > "$CONTENT"
if "$BINARY" setup --runtime-package "$PACKAGE_ROOT" --game "$GAME_DIR" --assume-clean >/dev/null 2>&1; then
    fail "invalid requested runtime package was accepted"
fi
[ "$(cat "$CONTENT")" = "sentinel-before-runtime-gate" ] \
    || fail "invalid runtime package changed the archive"

echo "runtime framework CLI test passed"

