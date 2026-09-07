#!/usr/bin/env bash
# The low-level `patch` and `patch-hashes` commands rewrite official archives
# in place. Both must refuse while the game is running, for the same reason
# `run` and `restore` do: the live session reads whatever is on disk next.
set -euo pipefail

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="${1:-$REPOSITORY_DIR/patcher/.build/release/archive-loader}"
FIXTURES="$REPOSITORY_DIR/tests/fixtures"

[ -x "$BINARY" ] || { echo "ERROR: no binary at $BINARY" >&2; exit 1; }

WORK_DIR="$(mktemp -d /private/tmp/archive-loader-patch-test.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() { echo "ERROR: $1" >&2; exit 1; }

cc -o "$WORK_DIR/fakegame" "$FIXTURES/fakegame.c"
GAME_DIR="$WORK_DIR/Cyberpunk 2077"
CONTENT="$GAME_DIR/archive/Mac/content/basegame_1_engine.archive"
MOD="$WORK_DIR/mod.archive"

mkdir -p "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS" "$GAME_DIR/archive/Mac/content"
cp "$WORK_DIR/fakegame" "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
plutil -create xml1 "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string 2.3.1 \
    "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
printf 'vanilla-bytes' > "$CONTENT"
printf 'mod-bytes' > "$MOD"

ARCHIVE_LOADER_FAKE_SLEEP=6 "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077" &
game_pid=$!
sleep 0.5

# --- patch refuses ----------------------------------------------------------
set +e
output="$("$BINARY" patch --game "$GAME_DIR" --mods "$MOD" 2>&1)"; code=$?
set -e
[ "$code" -ne 0 ] || fail "patch ran while the game was live"
case "$output" in *running*) ;; *) fail "the patch refusal did not mention the game: $output" ;; esac

# --- patch-hashes refuses ---------------------------------------------------
set +e
output="$("$BINARY" patch-hashes --game "$GAME_DIR" --source "$MOD" \
    --target "$CONTENT" --hashes deadbeef 2>&1)"; code=$?
set -e
wait "$game_pid" 2>/dev/null || true
[ "$code" -ne 0 ] || fail "patch-hashes ran while the game was live"
case "$output" in *running*) ;; *) fail "the patch-hashes refusal did not mention the game: $output" ;; esac

[ "$(cat "$CONTENT")" = "vanilla-bytes" ] || fail "a refused patch still wrote to the archive"

echo "patch command test passed"
