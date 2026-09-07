#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="${1:-$REPOSITORY_DIR/patcher/.build/release/archive-loader}"
FIXTURES="$REPOSITORY_DIR/tests/fixtures"
[ -x "$BINARY" ] || { echo "ERROR: no binary at $BINARY" >&2; exit 1; }

WORK_DIR="$(mktemp -d /private/tmp/archive-loader-status-test.XXXXXX)"
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

# --- Clean install reports pristine and exits 0 -----------------------------
make_game
output="$("$BINARY" status --game "$GAME_DIR" 2>&1)" || fail "status failed on a clean install"
case "$output" in *pristine*) ;; *) fail "did not report pristine: $output" ;; esac

# --- A same-size change is invisible shallow, caught by --deep --------------
make_game
printf 'vandals-bytes' > "$CONTENT"   # exactly as long as 'vanilla-bytes'
"$BINARY" status --game "$GAME_DIR" > /dev/null 2>&1 \
    || fail "the shallow check should not have noticed a same-size change"
set +e
output="$("$BINARY" status --game "$GAME_DIR" --deep 2>&1)"; code=$?
set -e
[ "$code" -ne 0 ] || fail "--deep did not notice a same-size change"
case "$output" in *differs*) ;; *) fail "--deep did not report drift: $output" ;; esac

# --- A size change is caught even shallow -----------------------------------
make_game
printf 'a-much-longer-patched-payload' > "$CONTENT"
set +e
output="$("$BINARY" status --game "$GAME_DIR" 2>&1)"; code=$?
set -e
[ "$code" -ne 0 ] || fail "the shallow check missed a size change"
case "$output" in *"archive-loader restore"*) ;; *) fail "no recovery advice: $output" ;; esac

# --- A loose artifact is reported -------------------------------------------
make_game
touch "$GAME_DIR/archive/Mac/content/basegame_99_usermod.archive"
set +e
output="$("$BINARY" status --game "$GAME_DIR" 2>&1)"; code=$?
set -e
[ "$code" -ne 0 ] || fail "a loose archive was not reported"
case "$output" in *artifact*) ;; *) fail "artifact not named: $output" ;; esac

# --- A language pack added after capture is reported, not treated as damage -
make_game
printf 'added later' > "$GAME_DIR/archive/Mac/content/lang_de_voice.archive"
output="$("$BINARY" status --game "$GAME_DIR" 2>&1)" \
    || fail "an unrecorded official archive should not make status fail"
case "$output" in *"left alone"*) ;; *) fail "unrecorded archive not reported: $output" ;; esac

# --- status works while a run holds the lock --------------------------------
make_game
printf '#!/usr/bin/env bash\nexec "$(dirname "$0")/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"\n' \
    > "$GAME_DIR/launch.sh"
chmod +x "$GAME_DIR/launch.sh"
ARCHIVE_LOADER_FAKE_SLEEP=4 "$BINARY" run --game "$GAME_DIR" -- ./launch.sh > /dev/null 2>&1 &
runner=$!
sleep 1.5
# Read-only and lock-free on purpose: a live session is the moment a user most
# wants a status, and taking the lock would make it unavailable exactly then.
began=$(date +%s)
set +e
output="$("$BINARY" status --game "$GAME_DIR" 2>&1)"
set -e
elapsed=$(( $(date +%s) - began ))
wait "$runner" || true

[ "$elapsed" -lt 3 ] || fail "status took ${elapsed}s; it blocked on the installation lock"
case "$output" in
    *lock*) fail "status refused because of the lock: $output" ;;
    *) ;;
esac
case "$output" in
    *RUNNING*) ;;
    *) fail "status did not report the live session: $output" ;;
esac

# --- No baseline is reported, not crashed on ---------------------------------
rm -rf "$GAME_DIR"
mkdir -p "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS" "$GAME_DIR/archive/Mac/content"
cp "$WORK_DIR/fakegame" "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
plutil -create xml1 "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string 2.3.1 \
    "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
printf 'x' > "$CONTENT"
set +e
output="$("$BINARY" status --game "$GAME_DIR" 2>&1)"; code=$?
set -e
[ "$code" -ne 0 ] || fail "status passed without a baseline"
case "$output" in *"archive-loader setup"*) ;; *) fail "no setup advice: $output" ;; esac

echo "status command test passed"
