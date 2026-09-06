#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="${1:-$REPOSITORY_DIR/patcher/.build/release/archive-loader}"
SETUP_SH="$REPOSITORY_DIR/release/payload/archive-loader/setup.sh"
FIXTURES="$REPOSITORY_DIR/tests/fixtures"
[ -x "$BINARY" ] || { echo "ERROR: no binary at $BINARY" >&2; exit 1; }

WORK_DIR="$(mktemp -d /private/tmp/archive-loader-setupsh-test.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT
fail() { echo "ERROR: $1" >&2; exit 1; }

cc -o "$WORK_DIR/fakegame" "$FIXTURES/fakegame.c"
GAME_DIR="$WORK_DIR/Cyberpunk 2077"

make_game() {
    rm -rf "$GAME_DIR"
    mkdir -p "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS" "$GAME_DIR/archive/Mac/content"
    cp "$WORK_DIR/fakegame" "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
    plutil -create xml1 "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
    plutil -insert CFBundleShortVersionString -string 2.3.1 \
        "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
    printf 'vanilla' > "$GAME_DIR/archive/Mac/content/basegame_1_engine.archive"
}

install_payload() {   # $1 = destination directory name
    local dest="$GAME_DIR/$1"
    mkdir -p "$dest/bin" "$dest/mods/enabled"
    cp "$BINARY" "$dest/bin/archive-loader"
    cp "$SETUP_SH" "$dest/setup.sh"
    printf '%s\n' "0.1.0" > "$dest/version"
    chmod +x "$dest/setup.sh" "$dest/bin/archive-loader"
}

# --- Quarantine is cleared and reported -------------------------------------
make_game
install_payload "archive-loader"
xattr -w com.apple.quarantine "0081;00000000;Safari;" \
    "$GAME_DIR/archive-loader/bin/archive-loader"

output="$("$GAME_DIR/archive-loader/setup.sh" --assume-clean 2>&1)" \
    || fail "setup.sh failed: $output"
case "$output" in *quarantine*) ;; *) fail "setup.sh did not report clearing it: $output" ;; esac
if xattr -p com.apple.quarantine "$GAME_DIR/archive-loader/bin/archive-loader" > /dev/null 2>&1; then
    fail "quarantine was not cleared"
fi
[ -L "$GAME_DIR/archive-loader/pristine" ] || fail "setup.sh did not reach the binary"

# --- The Archive Utility re-extraction shape is merged ----------------------
# Archive Utility is not scriptable and no CLI extractor reproduces its
# disambiguation, so this constructs the sibling it would leave and asserts
# the merge, not the extractor.
mkdir -p "$GAME_DIR/archive-loader/mods/enabled" "$GAME_DIR/archive-loader/logs"
printf 'a mod' > "$GAME_DIR/archive-loader/mods/enabled/keepme.archive"
printf 'keep this log' > "$GAME_DIR/archive-loader/logs/session.log"
BASELINE_ID="$(readlink "$GAME_DIR/archive-loader/pristine")"

install_payload "archive-loader 2"
printf '%s\n' "0.2.0" > "$GAME_DIR/archive-loader 2/version"
printf 'NEWER BINARY\n' > "$GAME_DIR/archive-loader 2/bin/archive-loader"
chmod +x "$GAME_DIR/archive-loader 2/bin/archive-loader"

set +e
"$GAME_DIR/archive-loader 2/setup.sh" --assume-clean > /dev/null 2>&1
set -e

if [ -d "$GAME_DIR/archive-loader 2" ]; then fail "the duplicate was not removed"; fi
[ "$(cat "$GAME_DIR/archive-loader/version")" = "0.2.0" ] \
    || fail "the upgraded version file did not land"
grep -q "NEWER BINARY" "$GAME_DIR/archive-loader/bin/archive-loader" \
    || fail "the upgraded binary did not land"

# The user's data must survive the upgrade untouched.
[ -f "$GAME_DIR/archive-loader/mods/enabled/keepme.archive" ] || fail "mods were lost"
[ "$(readlink "$GAME_DIR/archive-loader/pristine")" = "$BASELINE_ID" ] \
    || fail "the baseline pointer was replaced"
[ -d "$GAME_DIR/archive-loader/baselines/$(basename "$BASELINE_ID")" ] \
    || fail "the baseline generation was lost"
[ -d "$GAME_DIR/archive-loader/state" ] || fail "state was lost"
[ -f "$GAME_DIR/archive-loader/logs/session.log" ] || fail "logs were lost"
[ "$(cat "$GAME_DIR/archive-loader/logs/session.log")" = "keep this log" ] \
    || fail "log contents changed"

echo "setup.sh test passed"
