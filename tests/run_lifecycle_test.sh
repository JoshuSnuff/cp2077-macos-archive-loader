#!/usr/bin/env bash
# Exit codes, signals, early-return launchers, zero mods, and the refusals.
set -euo pipefail

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="${1:-$REPOSITORY_DIR/patcher/.build/release/archive-loader}"
FIXTURES="$REPOSITORY_DIR/tests/fixtures"

[ -x "$BINARY" ] || { echo "ERROR: no binary at $BINARY" >&2; exit 1; }

WORK_DIR="$(mktemp -d /private/tmp/archive-loader-lifecycle-test.XXXXXX)"
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
    cat > "$GAME_DIR/launch.sh" <<'LAUNCHER'
#!/usr/bin/env bash
exec "$(dirname "$0")/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
LAUNCHER
    chmod +x "$GAME_DIR/launch.sh"
}

# --- Zero mods: restores, cleans up, and launches ---------------------------
make_game
output="$("$BINARY" run --game "$GAME_DIR" -- ./launch.sh 2>&1)" \
    || fail "a zero-mod run should succeed: $output"
case "$output" in
    *"No mods"*) ;;
    *) fail "a zero-mod run did not say so: $output" ;;
esac
[ "$(cat "$CONTENT")" = "vanilla-bytes" ] || fail "zero-mod run left the install changed"

# --- A non-zero launcher exit is passed through -----------------------------
make_game
set +e
ARCHIVE_LOADER_FAKE_EXIT=3 "$BINARY" run --game "$GAME_DIR" -- ./launch.sh > /dev/null 2>&1
code=$?
set -e
[ "$code" -eq 3 ] || fail "expected exit 3, got $code"
[ "$(cat "$CONTENT")" = "vanilla-bytes" ] || fail "restore did not run after a failing launcher"

# --- A launcher that returns early does not trigger an early restore --------
make_game
cat > "$GAME_DIR/early.sh" <<'LAUNCHER'
#!/usr/bin/env bash
# Backgrounds the game and returns immediately, as an `open -a` launcher would.
"$(dirname "$0")/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077" &
exit 0
LAUNCHER
chmod +x "$GAME_DIR/early.sh"

began=$(date +%s)
ARCHIVE_LOADER_FAKE_SLEEP=3 "$BINARY" run --game "$GAME_DIR" -- ./early.sh > /dev/null 2>&1 \
    || fail "the early-return run failed"
elapsed=$(( $(date +%s) - began ))
[ "$elapsed" -ge 3 ] \
    || fail "run returned after ${elapsed}s; it did not wait for the backgrounded game"

# --- SIGTERM during the surviving game wait still restores ------------------
make_game
cat > "$GAME_DIR/early_term.sh" <<'LAUNCHER'
#!/usr/bin/env bash
printf 'mutated-during-session' > "$(dirname "$0")/archive/Mac/content/basegame_1_engine.archive"
"$(dirname "$0")/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077" &
exit 0
LAUNCHER
chmod +x "$GAME_DIR/early_term.sh"

began=$(date +%s)
ARCHIVE_LOADER_FAKE_SLEEP=3 ARCHIVE_LOADER_FAKE_IGNORE_TERM=1 \
    "$BINARY" run --game "$GAME_DIR" -- ./early_term.sh > /dev/null 2>&1 &
runner=$!
sleep 1.5
kill -TERM "$runner"
set +e
wait "$runner"
code=$?
set -e
[ "$code" -eq 143 ] || fail "SIGTERM during game wait exited $code, expected 143"
elapsed=$(( $(date +%s) - began ))
[ "$elapsed" -ge 3 ] \
    || fail "SIGTERM returned after ${elapsed}s; it killed the wrapper before cleanup"
pgrep -f "$GAME_DIR/Cyberpunk2077.app" > /dev/null \
    && fail "SIGTERM during game wait left the game running"
[ "$(cat "$CONTENT")" = "vanilla-bytes" ] \
    || fail "SIGTERM during game wait did not restore the baseline"

# --- A game already running is refused before anything is touched -----------
make_game
ARCHIVE_LOADER_FAKE_SLEEP=5 "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077" &
game_pid=$!
sleep 0.5
set +e
output="$("$BINARY" run --game "$GAME_DIR" -- ./launch.sh 2>&1)"
code=$?
set -e
wait "$game_pid" 2>/dev/null || true
[ "$code" -ne 0 ] || fail "run proceeded while the game was already running"
case "$output" in
    *"already running"*) ;;
    *) fail "the refusal did not say the game was running: $output" ;;
esac

# --- Without a baseline, run refuses and names setup ------------------------
rm -rf "$GAME_DIR"
mkdir -p "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS" "$GAME_DIR/archive/Mac/content"
cp "$WORK_DIR/fakegame" "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
plutil -create xml1 "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string 2.3.1 \
    "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
printf 'vanilla-bytes' > "$CONTENT"
printf '#!/usr/bin/env bash\nexit 0\n' > "$GAME_DIR/launch.sh"
chmod +x "$GAME_DIR/launch.sh"

set +e
output="$("$BINARY" run --game "$GAME_DIR" -- ./launch.sh 2>&1)"
code=$?
set -e
[ "$code" -ne 0 ] || fail "run proceeded without a baseline"
case "$output" in
    *"archive-loader setup"*) ;;
    *) fail "the refusal did not name setup: $output" ;;
esac

# --- A game update is refused and names --rebaseline ------------------------
make_game
plutil -replace CFBundleShortVersionString -string 2.4.0 \
    "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
set +e
output="$("$BINARY" run --game "$GAME_DIR" -- ./launch.sh 2>&1)"
code=$?
set -e
[ "$code" -ne 0 ] || fail "run proceeded against an updated game"
case "$output" in
    *--rebaseline*) ;;
    *) fail "the version refusal did not name --rebaseline: $output" ;;
esac

# --- A second run is refused while the first holds the lock -----------------
make_game
ARCHIVE_LOADER_FAKE_SLEEP=4 "$BINARY" run --game "$GAME_DIR" -- ./launch.sh > /dev/null 2>&1 &
first=$!
sleep 1.5
set +e
output="$("$BINARY" run --game "$GAME_DIR" -- ./launch.sh 2>&1)"
code=$?
set -e
wait "$first" || true
[ "$code" -ne 0 ] || fail "a second concurrent run was allowed"
case "$output" in
    *"already running"*|*lock*) ;;
    *) fail "the concurrent refusal was unclear: $output" ;;
esac
[ "$(cat "$CONTENT")" = "vanilla-bytes" ] || fail "the refused second run touched the archives"

# --- Ctrl-C ends the game and still restores --------------------------------
make_game
ARCHIVE_LOADER_FAKE_SLEEP=10 "$BINARY" run --game "$GAME_DIR" -- ./launch.sh > /dev/null 2>&1 &
runner=$!
sleep 1.5
kill -INT "$runner"
set +e
wait "$runner"
code=$?
set -e

# 130 = 128 + SIGINT. The signal must reach the child rather than killing the
# wrapper and orphaning a patched install.
[ "$code" -eq 130 ] || fail "SIGINT run exited $code, expected 130"
[ "$(cat "$CONTENT")" = "vanilla-bytes" ] \
    || fail "Ctrl-C left the install patched"
pgrep -f "$GAME_DIR/Cyberpunk2077.app" > /dev/null \
    && fail "Ctrl-C left the game running"

# --- SIGKILL is uncatchable; the NEXT run is what recovers ------------------
make_game
cat > "$GAME_DIR/sigkill.sh" <<LAUNCHER
#!/usr/bin/env bash
exec "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
LAUNCHER
chmod +x "$GAME_DIR/sigkill.sh"
ARCHIVE_LOADER_FAKE_SLEEP=10 "$BINARY" run --game "$GAME_DIR" -- ./sigkill.sh > /dev/null 2>&1 &
runner=$!
sleep 1.5
kill -KILL "$runner"
wait "$runner" 2>/dev/null || true
pkill -f "$GAME_DIR/Cyberpunk2077.app" 2>/dev/null || true
sleep 0.5

# Nothing can run on SIGKILL, so the install stays as it was. Recovery is
# restore-before-every-run, and the kernel must have dropped the lock with the
# dead holder rather than wedging every later run.
"$BINARY" run --game "$GAME_DIR" -- ./launch.sh > /dev/null 2>&1 \
    || fail "a run after a SIGKILLed session failed; the lock may be wedged"
[ "$(cat "$CONTENT")" = "vanilla-bytes" ] \
    || fail "the recovery run did not restore the install"

# --- Restore failure is never swallowed -------------------------------------
make_game
# The launcher breaks the baseline on its way out, so the pre-launch restore
# succeeds and only the post-exit one fails.
cat > "$GAME_DIR/sabotage.sh" <<LAUNCHER
#!/usr/bin/env bash
chmod 000 "$GAME_DIR/archive-loader/pristine/content" 2>/dev/null
exit 0
LAUNCHER
chmod +x "$GAME_DIR/sabotage.sh"

set +e
output="$("$BINARY" run --game "$GAME_DIR" -- ./sabotage.sh 2>&1)"
code=$?
set -e
chmod 755 "$GAME_DIR/archive-loader/pristine/content" 2>/dev/null || true

# A clean launcher exit must not hide a failed restore: the install is still
# patched, which is the more urgent of the two facts.
[ "$code" -eq 70 ] || fail "restore failure exited $code, expected 70"
case "$output" in
    *"RESTORE FAILED"*) ;;
    *) fail "the restore failure was not reported: $output" ;;
esac
case "$output" in
    *"Recover with"*) ;;
    *) fail "no recovery command was printed: $output" ;;
esac
# grep, not rg: ripgrep is not a macOS built-in and not a dependency this
# project declares, so a contributor running the suite would see this fail for
# a reason that has nothing to do with the loader.
printf '%s\n' "$output" | grep -q "cd '.*/Cyberpunk 2077'" \
    || fail "the recovery command did not quote the game path: $output"

echo "run lifecycle test passed"
