#!/usr/bin/env bash
# Focused Task 3 CLI coverage: offline tweak build and command discovery.
set -euo pipefail

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="${1:-$REPOSITORY_DIR/patcher/.build/release/archive-loader}"

[ -x "$BINARY" ] || { echo "ERROR: no binary at $BINARY" >&2; exit 1; }

WORK_DIR="$(mktemp -d /private/tmp/archive-loader-tweaks-cli-test.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT
fail() { echo "ERROR: $1" >&2; exit 1; }

GAME_DIR="$WORK_DIR/Cyberpunk 2077"
mkdir -p "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS" \
    "$GAME_DIR/archive/Mac/content" \
    "$GAME_DIR/r6/cache"
touch "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
chmod +x "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
plutil -create xml1 "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string 2.5.0 \
    "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
printf 'vanilla-archive' > "$GAME_DIR/archive/Mac/content/basegame_1_engine.archive"

output="$("$BINARY" tweaks build --game "$GAME_DIR" 2>&1)" \
    || fail "tweaks build failed without tweak mods: $output"
case "$output" in
    *"no tweak mods"*) ;;
    *) fail "empty tweak build did not report no tweak mods: $output" ;;
esac

# Minimal byte-identical TweakDB: header, empty type table, then empty record,
# query, and group-tag sections.
printf '\x47\xdb\xb1\x0b\x08\x00\x00\x00\x04\x00\x00\x00\x93\xca\xde\x69\x20\x00\x00\x00\x24\x00\x00\x00\x28\x00\x00\x00\x2c\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00' \
    > "$GAME_DIR/r6/cache/tweakdb.bin"
setup_output="$("$BINARY" setup --assume-clean --game "$GAME_DIR" 2>&1)" \
    || fail "setup failed for malformed tweak preflight fixture: $setup_output"

printf 'live-archive-must-remain' > "$GAME_DIR/archive/Mac/content/basegame_1_engine.archive"
printf 'live-blob-must-remain' > "$GAME_DIR/r6/cache/tweakdb.bin"
mkdir -p "$GAME_DIR/archive-loader/mods/tweaks"
printf 'this: [is: not: valid\n' > "$GAME_DIR/archive-loader/mods/tweaks/malformed.yaml"

if "$BINARY" tweaks build --no-cache --game "$GAME_DIR" >/dev/null 2>&1; then
    fail "malformed tweak preflight unexpectedly succeeded"
fi
[ "$(cat "$GAME_DIR/archive/Mac/content/basegame_1_engine.archive")" = \
    'live-archive-must-remain' ] || fail "malformed tweak preflight changed a live archive"
[ "$(cat "$GAME_DIR/r6/cache/tweakdb.bin")" = 'live-blob-must-remain' ] \
    || fail "malformed tweak preflight changed a live TweakDB blob"

echo "tweaks CLI test passed"
