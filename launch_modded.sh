#!/usr/bin/env bash
set -euo pipefail

GAME_DIR="${ARCHIVE_LOADER_GAME_DIR:-}"
if [ -z "$GAME_DIR" ]; then
    echo "ERROR: ARCHIVE_LOADER_GAME_DIR is not set. Export it to point at your Cyberpunk 2077 install." >&2
    echo "  e.g. export ARCHIVE_LOADER_GAME_DIR=\"/path/to/Cyberpunk 2077\"" >&2
    exit 1
fi

RUNTIME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$GAME_DIR"

# 1. Warn if the live RED4ext/runtime files have drifted from the repository.
"$RUNTIME_DIR/sync_gamefiles.sh" --check || true

# 2. Archive mod injection (restores pristine first, then patches if mods exist)
"$RUNTIME_DIR/inject_archives.sh" || true

# 3. Compile REDscript
"$GAME_DIR/engine/tools/scc" -compile "$GAME_DIR/r6/scripts" || true

# 4. Process input mappings
"$GAME_DIR/engine/tools/inputloader.pl" || true

# 5. RED4ext injection
INJECT_LIBS="$GAME_DIR/red4ext/RED4ext.dylib"
[ -f "$GAME_DIR/red4ext/FridaGadget.dylib" ] && INJECT_LIBS="$INJECT_LIBS:$GAME_DIR/red4ext/FridaGadget.dylib"
export DYLD_INSERT_LIBRARIES="$INJECT_LIBS"
export DYLD_FORCE_FLAT_NAMESPACE=1

# 6. Restore pristine archives on every exit path — clean quit, crash, or Ctrl-C.
# A patched install stays broken until this runs, so it must not be skippable.
restored=0
restore_on_exit() {
    [ "$restored" -eq 1 ] && return
    restored=1
    "$RUNTIME_DIR/restore_archives.sh" || true
}
trap restore_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# 7. Launch game (no exec — need post-exit cleanup)
game_exit=0
"$GAME_DIR/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077" "$@" || game_exit=$?

exit $game_exit
