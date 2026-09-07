#!/usr/bin/env bash
# Recovery after a crash: the case where nothing else worked.
set -euo pipefail

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="${1:-$REPOSITORY_DIR/patcher/.build/release/archive-loader}"
FIXTURES="$REPOSITORY_DIR/tests/fixtures"
[ -x "$BINARY" ] || { echo "ERROR: no binary at $BINARY" >&2; exit 1; }

WORK_DIR="$(mktemp -d /private/tmp/archive-loader-restore-test.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT
fail() { echo "ERROR: $1" >&2; exit 1; }

cc -o "$WORK_DIR/fakegame" "$FIXTURES/fakegame.c"
GAME_DIR="$WORK_DIR/Cyberpunk 2077"
CONTENT="$GAME_DIR/archive/Mac/content/basegame_1_engine.archive"

make_game() {
    rm -rf "$GAME_DIR"
    mkdir -p "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS" "$GAME_DIR/archive/Mac/content"
    cp "$WORK_DIR/fakegame" "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
    plutil -create xml1 "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
    plutil -insert CFBundleShortVersionString -string 2.3.1 \
        "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
    printf 'vanilla-bytes' > "$CONTENT"
    "$BINARY" setup --game "$GAME_DIR" --assume-clean > /dev/null || fail "setup failed"
}

# --- Restores a patched install and says it is clean ------------------------
make_game
printf 'patched-rubbish' > "$CONTENT"
output="$("$BINARY" restore --game "$GAME_DIR" 2>&1)" || fail "restore failed: $output"
[ "$(cat "$CONTENT")" = "vanilla-bytes" ] || fail "restore did not return the archive"
case "$output" in
    *"match the baseline"*) ;;
    *) fail "restore did not confirm the install is clean: $output" ;;
esac
case "$output" in
    *"safe to delete"*) ;;
    *) fail "restore did not say archive-loader/ can be removed: $output" ;;
esac

# --- An unrecorded basegame_99_ archive is never deleted --------------------
# The prefix is the documented way to hand-install a new-content mod, so a user
# may well own one. Nothing recorded it in state/, so it is not ours to remove.
make_game
FOREIGN="$GAME_DIR/archive/Mac/content/basegame_99_usermod.archive"
printf 'hand installed' > "$FOREIGN"
output="$("$BINARY" restore --game "$GAME_DIR" 2>&1)" \
    || fail "restore failed with a foreign archive"
[ -f "$FOREIGN" ] || fail "restore deleted a hand-installed basegame_99_ mod"

# Restore succeeded, so it exits 0 — but the install is not back to stock, and
# saying "safe to delete archive-loader/" here would be the false claim this
# check exists to prevent. It reported a clean install with 1.7 GB of leftover
# sitting in the game directory before this was fixed.
case "$output" in
    *"safe to delete"*)
        fail "restore claimed archive-loader/ was safe to delete with a file outstanding: $output" ;;
    *) ;;
esac
case "$output" in
    *"left alone"*) ;;
    *) fail "restore did not report the outstanding file: $output" ;;
esac

# status answers a different question and must still call this dirty.
if "$BINARY" status --game "$GAME_DIR" > /dev/null 2>&1; then
    fail "status reported pristine with a loose archive present"
fi

# --- The lock covers restore, not just run ----------------------------------
# Without this, a restore typed in another terminal during a live session would
# rewrite archives underneath the running game.
make_game
printf '#!/usr/bin/env bash\nexec "$(dirname "$0")/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"\n' \
    > "$GAME_DIR/launch.sh"
chmod +x "$GAME_DIR/launch.sh"
printf 'patched-rubbish' > "$CONTENT"

ARCHIVE_LOADER_FAKE_SLEEP=4 "$BINARY" run --game "$GAME_DIR" -- ./launch.sh > /dev/null 2>&1 &
runner=$!
sleep 1.5
set +e
output="$("$BINARY" restore --game "$GAME_DIR" 2>&1)"; code=$?
set -e
wait "$runner" || true

[ "$code" -ne 0 ] || fail "a concurrent restore was allowed during a live run"
case "$output" in
    *running*|*lock*) ;;
    *) fail "the concurrent refusal was unclear: $output" ;;
esac

# --- Without a baseline it refuses and names setup --------------------------
rm -rf "$GAME_DIR"
mkdir -p "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS" "$GAME_DIR/archive/Mac/content"
cp "$WORK_DIR/fakegame" "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
plutil -create xml1 "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string 2.3.1 \
    "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
printf 'x' > "$CONTENT"
set +e
output="$("$BINARY" restore --game "$GAME_DIR" 2>&1)"; code=$?
set -e
[ "$code" -ne 0 ] || fail "restore proceeded without a baseline"
case "$output" in *"archive-loader setup"*) ;; *) fail "refusal did not name setup: $output" ;; esac

# --- A changed game version warns but still restores ------------------------
make_game
printf 'patched-rubbish' > "$CONTENT"
plutil -replace CFBundleShortVersionString -string 2.4.0 \
    "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
output="$("$BINARY" restore --game "$GAME_DIR" 2>&1)" \
    || fail "restore refused after a version change: $output"
# Recovery is exactly when we would rather not reason about the state, and the
# recorded bytes are the only vanilla available.
[ "$(cat "$CONTENT")" = "vanilla-bytes" ] || fail "version change blocked recovery"
case "$output" in *--rebaseline*) ;; *) fail "no rebaseline advice after restoring: $output" ;; esac

# --- Refused while the game is running --------------------------------------
make_game
ARCHIVE_LOADER_FAKE_SLEEP=5 "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077" &
pid=$!
sleep 0.5
set +e
output="$("$BINARY" restore --game "$GAME_DIR" 2>&1)"; code=$?
set -e
wait "$pid" 2>/dev/null || true
[ "$code" -ne 0 ] || fail "restore ran while the game was live"
case "$output" in *running*) ;; *) fail "refusal did not mention the running game: $output" ;; esac

echo "restore command test passed"
