#!/usr/bin/env bash
# Fixture-only regression coverage for durable run/setup/restore session logs.
set -euo pipefail

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="${1:-$REPOSITORY_DIR/patcher/.build/release/archive-loader}"
FIXTURES="$REPOSITORY_DIR/tests/fixtures"

[ -x "$BINARY" ] || { echo "ERROR: no binary at $BINARY" >&2; exit 1; }

WORK_DIR="$(mktemp -d /private/tmp/archive-loader-logging-test.XXXXXX)"
GAME_DIR="$WORK_DIR/Cyberpunk 2077"
CONTENT="$GAME_DIR/archive/Mac/content/basegame_1_engine.archive"
LOG_DIR="$GAME_DIR/archive-loader/logs"

cleanup() {
    [ -d "$GAME_DIR/archive-loader/pristine/content" ] \
        && chmod 755 "$GAME_DIR/archive-loader/pristine/content" 2>/dev/null || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() { echo "ERROR: $1" >&2; exit 1; }

cc -o "$WORK_DIR/fakegame" "$FIXTURES/fakegame.c"

make_game() {
    rm -rf "$GAME_DIR"
    mkdir -p "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS" "$GAME_DIR/archive/Mac/content"
    cp "$WORK_DIR/fakegame" "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
    plutil -create xml1 "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
    plutil -insert CFBundleShortVersionString -string 2.3.1 \
        "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
    printf 'vanilla-bytes' > "$CONTENT"
    printf '%s\n' '#!/usr/bin/env bash' \
        'exec "$(dirname "$0")/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"' > "$GAME_DIR/launch.sh"
    chmod +x "$GAME_DIR/launch.sh"
}

one_file() { # $1 = description, remaining arguments = glob results
    local description="$1"
    shift
    local matches=("$@")

    [ "${#matches[@]}" -eq 1 ] || fail "expected one $description, found ${#matches[@]}"
    printf '%s\n' "${matches[0]}"
}

setup_game() {
    "$BINARY" setup --game "$GAME_DIR" --assume-clean > /dev/null \
        || fail "fixture setup failed"
}

# A normal run writes one text session record, atomically makes it current, and
# does not opt into the machine-readable debug stream.
shopt -s nullglob
make_game
setup_game
"$BINARY" run --game "$GAME_DIR" -- ./launch.sh > /dev/null \
    || fail "normal run failed"
normal_log="$(one_file 'normal run log' "$LOG_DIR"/run-*.log)"
[ -s "$normal_log" ] || fail "normal run log is empty"
[ -L "$LOG_DIR/latest.log" ] || fail "normal run did not publish latest.log"
[ "$(readlink "$LOG_DIR/latest.log")" = "$(basename "$normal_log")" ] \
    || fail "latest.log does not use the normal run log as its relative target"
normal_json=("$LOG_DIR"/run-*.jsonl)
[ "${#normal_json[@]}" -eq 0 ] || fail "normal run wrote a debug JSONL stream"

# Debug is an explicit opt-in: it preserves the text record and adds one JSONL
# sibling for the same run session.
make_game
setup_game
"$BINARY" run --debug --game "$GAME_DIR" -- ./launch.sh > /dev/null \
    || fail "debug run failed"
debug_log="$(one_file 'debug run log' "$LOG_DIR"/run-*.log)"
debug_json="$(one_file 'debug run JSONL stream' "$LOG_DIR"/run-*.jsonl)"
[ -s "$debug_log" ] || fail "debug run log is empty"
[ -s "$debug_json" ] || fail "debug run JSONL stream is empty"
[ "${debug_log%.log}" = "${debug_json%.jsonl}" ] \
    || fail "debug text and JSONL logs are not paired by session timestamp"

# Restore records its own invocation but never treats earlier session logs as
# cleanup artifacts.
before_restore="$(cat "$debug_log")"
"$BINARY" restore --game "$GAME_DIR" > /dev/null \
    || fail "restore failed"
[ -f "$debug_log" ] || fail "restore removed the prior run log"
[ "$(cat "$debug_log")" = "$before_restore" ] \
    || fail "restore modified the prior run log"

# The post-launch restore failure takes the real exit(70) path. Its terminal
# failure must already be durable: exit() bypasses deferred flushing.
make_game
setup_game
printf '%s\n' '#!/usr/bin/env bash' \
    'chmod 000 "$(dirname "$0")/archive-loader/pristine/content"' \
    'exit 0' > "$GAME_DIR/sabotage.sh"
chmod +x "$GAME_DIR/sabotage.sh"
set +e
"$BINARY" run --game "$GAME_DIR" -- ./sabotage.sh > /dev/null 2>&1
code=$?
set -e
chmod 755 "$GAME_DIR/archive-loader/pristine/content" 2>/dev/null || true
[ "$code" -eq 70 ] || fail "failed restore exited $code, expected 70"
failed_log="$(one_file 'failed restore run log' "$LOG_DIR"/run-*.log)"
tail -n 1 "$failed_log" | grep -q 'RESTORE FAILED' \
    || fail "failed restore log tail was not persisted"

# Logs are expected user data, not negative evidence. Setup must accept an
# existing logs directory and leave its unrelated contents untouched.
make_game
mkdir -p "$LOG_DIR"
printf 'pre-existing user log\n' > "$LOG_DIR/keep.txt"
"$BINARY" setup --game "$GAME_DIR" --assume-clean > /dev/null \
    || fail "setup rejected an install with an existing logs directory"
[ -L "$GAME_DIR/archive-loader/pristine" ] \
    || fail "setup with existing logs did not publish a baseline"
[ "$(cat "$LOG_DIR/keep.txt")" = 'pre-existing user log' ] \
    || fail "setup changed an unrelated existing log file"

shopt -u nullglob

echo "logging test passed"
