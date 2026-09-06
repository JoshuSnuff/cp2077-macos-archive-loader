#!/usr/bin/env bash
# Covers the two --rebaseline modes and the dead end between them.
#
# Getting this wrong writes the old build's archives over an updated install
# and then records the result as vanilla, which is the worst outcome available
# here, so each mode is asserted separately.
set -euo pipefail

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="${1:-$REPOSITORY_DIR/patcher/.build/release/archive-loader}"

if [ ! -x "$BINARY" ]; then
    echo "ERROR: no binary at $BINARY" >&2
    exit 1
fi

WORK_DIR="$(mktemp -d /private/tmp/archive-loader-rebaseline-test.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
    echo "ERROR: $1" >&2
    exit 1
}

GAME_DIR="$WORK_DIR/Cyberpunk 2077"
CONTENT="$GAME_DIR/archive/Mac/content/basegame_1_engine.archive"

set_version() {
    plutil -replace CFBundleShortVersionString -string "$1" \
        "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
}

make_game() {
    rm -rf "$GAME_DIR"
    mkdir -p "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS" "$GAME_DIR/archive/Mac/content"
    touch "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
    chmod +x "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
    plutil -create xml1 "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
    plutil -insert CFBundleShortVersionString -string 2.3.1 \
        "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
    printf 'original-2.3.1-bytes' > "$CONTENT"
    "$BINARY" setup --game "$GAME_DIR" --assume-clean > /dev/null \
        || fail "initial setup failed"
}

# --- 1. Same version: restores first, then recaptures ------------------------
make_game
printf 'patched-rubbish' > "$CONTENT"

"$BINARY" setup --game "$GAME_DIR" --rebaseline --assume-clean > /dev/null \
    || fail "same-version rebaseline failed"

[ "$(cat "$CONTENT")" = "original-2.3.1-bytes" ] \
    || fail "same-version rebaseline did not restore before recapturing"
grep -q '"gameVersion" : "2.3.1"' "$GAME_DIR/archive-loader/pristine/baseline.json" \
    || fail "the recaptured manifest has the wrong version"

# --- 2. Changed version: never restores -------------------------------------
make_game
# The storefront updated the game: new bytes, new version.
printf 'new-2.4.0-bytes' > "$CONTENT"
set_version 2.4.0

"$BINARY" setup --game "$GAME_DIR" --rebaseline --assume-clean > /dev/null \
    || fail "changed-version rebaseline failed"

[ "$(cat "$CONTENT")" = "new-2.4.0-bytes" ] \
    || fail "changed-version rebaseline restored the OLD build over the new install"
grep -q '"gameVersion" : "2.4.0"' "$GAME_DIR/archive-loader/pristine/baseline.json" \
    || fail "the recaptured manifest did not record the new version"

# --- 3. Dirty AND changed version: refuse, name verify/repair ---------------
make_game
printf 'new-2.4.0-bytes' > "$CONTENT"
set_version 2.4.0
touch "$GAME_DIR/archive/Mac/content/basegame_99_leftover.archive"

if output="$("$BINARY" setup --game "$GAME_DIR" --rebaseline --assume-clean 2>&1)"; then
    fail "rebaseline proceeded from a dirty install at a changed version"
fi
case "$output" in
    *verify*|*repair*) ;;
    *) fail "the refusal did not name verify/repair; got: $output" ;;
esac
[ "$(cat "$CONTENT")" = "new-2.4.0-bytes" ] \
    || fail "the refused rebaseline still wrote to the install"

# --- 4. Rebaseline without an existing baseline behaves like a first capture -
rm -rf "$GAME_DIR"
mkdir -p "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS" "$GAME_DIR/archive/Mac/content"
touch "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
chmod +x "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
plutil -create xml1 "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string 2.3.1 \
    "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
printf 'fresh' > "$CONTENT"

"$BINARY" setup --game "$GAME_DIR" --rebaseline --assume-clean > /dev/null \
    || fail "rebaseline without an existing baseline failed"
[ -L "$GAME_DIR/archive-loader/pristine" ] \
    || fail "rebaseline did not publish a baseline"

echo "rebaseline test passed"
