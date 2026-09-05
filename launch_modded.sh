#!/usr/bin/env bash
set -euo pipefail

GAME_DIR="${CP2077_GAME_DIR:-}"
if [ -z "$GAME_DIR" ]; then
    echo "ERROR: CP2077_GAME_DIR is not set. Export it to point at your Cyberpunk 2077 install." >&2
    echo "  e.g. export CP2077_GAME_DIR=\"/path/to/Cyberpunk 2077\"" >&2
    exit 1
fi

RUNTIME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$GAME_DIR"

# 1. Archive mod injection (restores pristine first, then patches if mods exist)
"$RUNTIME_DIR/inject_archives.sh" || true

# 2. Compile REDscript
"$GAME_DIR/engine/tools/scc" -compile "$GAME_DIR/r6/scripts" || true

# 3. Process input mappings
"$GAME_DIR/engine/tools/inputloader.pl" || true

# 4. RED4ext injection
INJECT_LIBS="$GAME_DIR/red4ext/RED4ext.dylib"
[ -f "$GAME_DIR/red4ext/FridaGadget.dylib" ] && INJECT_LIBS="$INJECT_LIBS:$GAME_DIR/red4ext/FridaGadget.dylib"
export DYLD_INSERT_LIBRARIES="$INJECT_LIBS"
export DYLD_FORCE_FLAT_NAMESPACE=1

# 5. Launch game (no exec — need post-exit cleanup)
"$GAME_DIR/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077" "$@"
game_exit=$?

# 6. Post-exit: restore pristine archives
"$RUNTIME_DIR/restore_archives.sh" || true

exit $game_exit
