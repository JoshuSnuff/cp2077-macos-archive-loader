#!/usr/bin/env bash
# End-to-end coverage of `archive-loader setup` against a synthetic install.
#
# The Swift tests cover each piece; this covers the wiring: exit codes, the
# storefront-verify confirmation, and the launch command the user is told to
# run. It never touches a real game.
set -euo pipefail

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="${1:-$REPOSITORY_DIR/patcher/.build/release/archive-loader}"

if [ ! -x "$BINARY" ]; then
    echo "ERROR: no binary at $BINARY" >&2
    echo "  build it with: swift build -c release --package-path patcher" >&2
    exit 1
fi

WORK_DIR="$(mktemp -d /private/tmp/archive-loader-setup-test.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
    echo "ERROR: $1" >&2
    exit 1
}

# A real executable, so the running-game guard has a process to find.
cc -o "$WORK_DIR/fakegame" "$REPOSITORY_DIR/tests/fixtures/fakegame.c"

# A game directory whose name carries a space, as normal installs do.
GAME_DIR="$WORK_DIR/Cyberpunk 2077"
make_game() {
    rm -rf "$GAME_DIR"
    mkdir -p \
        "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS" \
        "$GAME_DIR/archive/Mac/content" \
        "$GAME_DIR/archive/Mac/ep1"
    cp "$WORK_DIR/fakegame" "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
    plutil -create xml1 "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
    plutil -insert CFBundleShortVersionString -string 2.3.1 \
        "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
    head -c 4096 /dev/urandom > "$GAME_DIR/archive/Mac/content/basegame_1_engine.archive"
    head -c 4096 /dev/urandom > "$GAME_DIR/archive/Mac/ep1/ep1_1_main.archive"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$GAME_DIR/launch_modded.sh"
    chmod +x "$GAME_DIR/launch_modded.sh"
}

# --- 1. A clean install captures a baseline ---------------------------------
make_game
output="$("$BINARY" setup --game "$GAME_DIR" --assume-clean 2>&1)" \
    || fail "setup failed on a clean install: $output"

[ -L "$GAME_DIR/archive-loader/pristine" ] \
    || fail "setup did not publish a pristine pointer"
[ -f "$GAME_DIR/archive-loader/pristine/baseline.json" ] \
    || fail "the published generation has no baseline.json"

case "$output" in
    *"archive-loader run -- ./launch_modded.sh"*) ;;
    *) fail "setup did not print the launch command; got: $output" ;;
esac

# The user's launcher must be untouched.
grep -q '^exit 0$' "$GAME_DIR/launch_modded.sh" \
    || fail "setup modified the user's launcher"

# --- 2. Re-running is a no-op that reprints the command ---------------------
before="$(cat "$GAME_DIR/archive-loader/pristine/baseline.json")"
output="$("$BINARY" setup --game "$GAME_DIR" --assume-clean 2>&1)" \
    || fail "re-running setup failed: $output"
after="$(cat "$GAME_DIR/archive-loader/pristine/baseline.json")"
[ "$before" = "$after" ] || fail "re-running setup replaced the baseline"
case "$output" in
    *"archive-loader run -- ./launch_modded.sh"*) ;;
    *) fail "re-run did not reprint the launch command" ;;
esac

# --- 3. The negative-evidence gate refuses ----------------------------------
make_game
touch "$GAME_DIR/archive/Mac/content/basegame_99_usermod.archive"
if output="$("$BINARY" setup --game "$GAME_DIR" --assume-clean 2>&1)"; then
    fail "setup captured a baseline despite a loose archive"
fi
case "$output" in
    *basegame_99_usermod.archive*) ;;
    *) fail "the refusal did not name the artifact; got: $output" ;;
esac
[ -e "$GAME_DIR/archive-loader/pristine" ] \
    && fail "a refused setup published a baseline"
[ -f "$GAME_DIR/archive/Mac/content/basegame_99_usermod.archive" ] \
    || fail "setup deleted a user's hand-installed archive"

# --- 4. Non-interactive without --assume-clean refuses rather than hanging --
make_game
if output="$("$BINARY" setup --game "$GAME_DIR" < /dev/null 2>&1)"; then
    fail "setup captured a baseline without confirmation"
fi
case "$output" in
    *--assume-clean*) ;;
    *) fail "the refusal did not mention --assume-clean; got: $output" ;;
esac

# --- 5. A piped stdin refuses rather than proceeding -------------------------
# A tty cannot be simulated without a pty, so this asserts the reachable half:
# whatever arrives on a non-tty stdin, setup must not capture a baseline from
# it. The interactive "y" path is exercised by hand.
make_game
if output="$(printf 'n\n' | "$BINARY" setup --game "$GAME_DIR" 2>&1)"; then
    fail "setup proceeded without an interactive confirmation"
fi
[ -e "$GAME_DIR/archive-loader/pristine" ] \
    && fail "a declined setup published a baseline"

# --- 6. A running game is refused, before and after --rebaseline ------------
# Capture reads the archives the live session is using, and a same-version
# --rebaseline restores them underneath it before recapturing.
make_game
ARCHIVE_LOADER_FAKE_SLEEP=6 "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077" &
game_pid=$!
sleep 0.5
set +e
output="$("$BINARY" setup --game "$GAME_DIR" --assume-clean 2>&1)"; code=$?
set -e
[ "$code" -ne 0 ] || fail "setup captured a baseline while the game was running"
case "$output" in *running*) ;; *) fail "the refusal did not mention the running game: $output" ;; esac
[ -e "$GAME_DIR/archive-loader/pristine" ] \
    && fail "a refused setup published a baseline"

set +e
output="$("$BINARY" setup --game "$GAME_DIR" --rebaseline --assume-clean 2>&1)"; code=$?
set -e
wait "$game_pid" 2>/dev/null || true
[ "$code" -ne 0 ] || fail "rebaseline ran while the game was live"
case "$output" in *running*) ;; *) fail "the rebaseline refusal did not mention the game: $output" ;; esac

echo "setup command test passed"
