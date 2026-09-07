#!/usr/bin/env bash
# The three injection tests.
#
# Nothing here has a symptom in normal use. A shell between the wrapper and
# the game strips DYLD_* and breaks every REDscript mod while archive mods
# keep working; a wrapper placed after the user's exports gets RED4ext loaded
# into itself and fourteen game-build offsets applied to its own address
# space. Only these tests would notice either.
set -euo pipefail

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="${1:-$REPOSITORY_DIR/patcher/.build/release/archive-loader}"
FIXTURES="$REPOSITORY_DIR/tests/fixtures"

[ -x "$BINARY" ] || { echo "ERROR: no binary at $BINARY" >&2; exit 1; }

WORK_DIR="$(mktemp -d /private/tmp/archive-loader-dyld-test.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() { echo "ERROR: $1" >&2; exit 1; }

cc -dynamiclib -o "$WORK_DIR/probe.dylib" "$FIXTURES/probe.c"
cc -o "$WORK_DIR/fakegame" "$FIXTURES/fakegame.c"

GAME_DIR="$WORK_DIR/Cyberpunk 2077"
mkdir -p "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS" \
         "$GAME_DIR/archive/Mac/content" "$GAME_DIR/archive/Mac/ep1"
cp "$WORK_DIR/fakegame" "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
plutil -create xml1 "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string 2.3.1 \
    "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
head -c 4096 /dev/urandom > "$GAME_DIR/archive/Mac/content/basegame_1_engine.archive"

"$BINARY" setup --game "$GAME_DIR" --assume-clean > /dev/null \
    || fail "setup failed on the fixture install"

# A launcher shaped like the real ones: exports DYLD_* and THEN runs the game.
cat > "$GAME_DIR/launch_modded.sh" <<LAUNCHER
#!/usr/bin/env bash
export DYLD_INSERT_LIBRARIES="$WORK_DIR/probe.dylib"
export DYLD_FORCE_FLAT_NAMESPACE=1
export ARCHIVE_LOADER_PROBE_MARKER="$WORK_DIR/game.marker"
exec "\$(dirname "\$0")/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
LAUNCHER
chmod +x "$GAME_DIR/launch_modded.sh"

# --- 1 & 2. Passthrough reaches the game; the wrapper is not injected -------
rm -f "$WORK_DIR/game.marker" "$WORK_DIR/wrapper.marker"
ARCHIVE_LOADER_PROBE_MARKER="$WORK_DIR/wrapper.marker" \
    "$BINARY" run --game "$GAME_DIR" -- ./launch_modded.sh > /dev/null \
    || fail "run failed against the fixture launcher"

[ -f "$WORK_DIR/game.marker" ] \
    || fail "DYLD_INSERT_LIBRARIES did not reach the game; something stripped it"
[ -f "$WORK_DIR/wrapper.marker" ] \
    && fail "the probe loaded into archive-loader itself"

# --- 3. An ambient DYLD_INSERT_LIBRARIES cannot inject the wrapper ----------
# __RESTRICT purges it from our process, while the child launcher setting its
# own still reaches the game.
rm -f "$WORK_DIR/game.marker" "$WORK_DIR/wrapper.marker"
DYLD_INSERT_LIBRARIES="$WORK_DIR/probe.dylib" \
ARCHIVE_LOADER_PROBE_MARKER="$WORK_DIR/wrapper.marker" \
    "$BINARY" run --game "$GAME_DIR" -- ./launch_modded.sh > /dev/null \
    || fail "run failed with an ambient DYLD_INSERT_LIBRARIES"

[ -f "$WORK_DIR/wrapper.marker" ] \
    && fail "an ambient DYLD_INSERT_LIBRARIES injected the wrapper"
[ -f "$WORK_DIR/game.marker" ] \
    || fail "the launcher's own DYLD_INSERT_LIBRARIES stopped reaching the game"

echo "dyld passthrough test passed"
