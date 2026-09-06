#!/usr/bin/env bash
# Read-only release installer preflight. Installation mutations are intentionally
# deferred until the discovery and payload contract have been validated.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=0
GAME_PATH=""

usage() {
    cat <<EOF
Usage: $(basename "$0") --dry-run [--game GAME_DIR]

  --dry-run         Detect and inspect the target without changing any files.
  --game GAME_DIR   Validate this game directory instead of auto-detecting one.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --game)
            if [ "$#" -lt 2 ]; then
                echo "ERROR: --game requires a directory" >&2
                usage >&2
                exit 2
            fi
            GAME_PATH="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ "$DRY_RUN" -ne 1 ]; then
    echo "ERROR: installation is not implemented yet; run with --dry-run for a read-only preflight" >&2
    exit 2
fi

PATCHER=""
for candidate in \
    "$SCRIPT_DIR/bin/archive-loader" \
    "$SCRIPT_DIR/payload/archive-loader/bin/archive-loader" \
    "$SCRIPT_DIR/release/payload/archive-loader/bin/archive-loader"; do
    if [ -x "$candidate" ]; then
        PATCHER="$candidate"
        break
    fi
done

if [ -z "$PATCHER" ]; then
    echo "ERROR: archive-loader executable was not found in the source or release payload" >&2
    exit 1
fi

detect_args=(detect)
if [ -n "$GAME_PATH" ]; then
    detect_args+=(--game "$GAME_PATH")
fi

if ! GAME_DIR="$("$PATCHER" "${detect_args[@]}")"; then
    echo "ERROR: game detection failed; pass --game with the installation directory" >&2
    exit 1
fi

APP="$GAME_DIR/Cyberpunk2077.app"
INFO_PLIST="$APP/Contents/Info.plist"
CONTENT_DIR="$GAME_DIR/archive/Mac/content"
EP1_DIR="$GAME_DIR/archive/Mac/ep1"
GAME_VERSION="unknown"
FAILED=0

if [ -x /usr/libexec/PlistBuddy ]; then
    GAME_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || true)"
fi
if [ -z "$GAME_VERSION" ]; then
    GAME_VERSION="unknown"
fi

check() {
    local description="$1"
    local result="$2"
    if [ "$result" -eq 0 ]; then
        echo "  OK    $description"
    else
        echo "  FAIL  $description"
        FAILED=1
    fi
}

echo "archive-loader installation preflight (DRY RUN)"
echo "Game: $GAME_DIR"
echo "Version: $GAME_VERSION"
echo ""
echo "Checks:"

machine_arch="$(uname -m)"
if [ "$machine_arch" = "arm64" ]; then
    check "Apple Silicon architecture ($machine_arch)" 0
else
    check "Apple Silicon architecture (found $machine_arch)" 1
fi

filesystem_device="$(df -P "$GAME_DIR" 2>/dev/null | awk 'NR == 2 { print $1 }')"
filesystem_type="$(/sbin/mount | awk -v device="$filesystem_device" '
    $1 == device {
        if (match($0, /\([^,]+/)) {
            print substr($0, RSTART + 1, RLENGTH - 1)
            exit
        }
    }
')"
if [ "$filesystem_type" = "apfs" ]; then
    check "APFS target filesystem" 0
else
    check "APFS target filesystem (found ${filesystem_type:-unknown})" 1
fi

if [ -w "$GAME_DIR" ]; then
    check "game root is writable" 0
else
    check "game root is writable" 1
fi

if [ -x "$APP/Contents/MacOS/Cyberpunk2077" ]; then
    check "game executable is present" 0
else
    check "game executable is present" 1
fi

if [ -d "$CONTENT_DIR" ]; then
    check "archive/Mac/content is present" 0
else
    check "archive/Mac/content is present" 1
fi

if [ -d "$EP1_DIR" ]; then
    check "archive/Mac/ep1 is present" 0
else
    echo "  INFO  archive/Mac/ep1 is absent (Phantom Liberty may not be installed)"
fi

echo ""
echo "Planned installation targets:"
echo "  $GAME_DIR/launch_modded.sh"
echo "  $GAME_DIR/restore_vanilla.sh"
echo "  $GAME_DIR/mods/enabled"
echo "  $GAME_DIR/mods/disabled"
echo "  $GAME_DIR/archive-loader"
echo ""
echo "No files were changed."

if [ "$FAILED" -ne 0 ]; then
    echo "Preflight failed." >&2
    exit 1
fi

echo "Preflight passed."
