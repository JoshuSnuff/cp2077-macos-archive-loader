#!/usr/bin/env bash
# Synchronizes the tracked RED4ext runtime files with the game installation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAMEFILES_DIR="$SCRIPT_DIR/gamefiles"
GAME_DIR="${CP2077_GAME_DIR:-}"
LOG_DIR="$SCRIPT_DIR/logs"
MODE="push"

usage() {
    cat <<EOF
Usage: $(basename "$0") [--check | --pull]

  no option  Copy managed files from this repository to the game directory.
  --check    Report differences without changing files; exit 1 if any differ.
  --pull     Copy managed files from the game directory into this repository.
EOF
}

if [ "$#" -gt 1 ]; then
    usage >&2
    exit 2
fi

if [ "$#" -eq 1 ]; then
    case "$1" in
        --check)
            MODE="check"
            ;;
        --pull)
            MODE="pull"
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
fi

if [ -z "$GAME_DIR" ]; then
    echo "ERROR: CP2077_GAME_DIR is not set. Export it to point at your Cyberpunk 2077 install." >&2
    echo "  e.g. export CP2077_GAME_DIR=\"/path/to/Cyberpunk 2077\"" >&2
    exit 1
fi

if [ ! -d "$GAME_DIR" ]; then
    echo "ERROR: game directory does not exist: $GAME_DIR" >&2
    exit 1
fi

mkdir -p "$LOG_DIR"
LOG_FILE="${SYNC_LOG_FILE:-$LOG_DIR/sync_$(date +%Y%m%d-%H%M%S).log}"

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }

STATIC_FILES=(
    "red4ext/red4ext_hooks.js"
    "red4ext/config.ini"
    "red4ext/FridaGadget.config"
    "red4ext/cyberpunk2077_addresses.json"
    "red4ext_entitlements.plist"
    "resign_for_red4ext.sh"
)

changed_count=0
difference_count=0

check_game_version() {
    local version_file="$GAMEFILES_DIR/README.md"
    local plist="$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
    local target_version=""
    local game_version=""

    if [ -f "$version_file" ]; then
        target_version="$(sed -n 's/^Target game version: //p' "$version_file")"
    fi

    if [ -z "$target_version" ]; then
        log "WARNING: Target game version is missing from gamefiles/README.md"
        return
    fi

    if [ -f "$plist" ] && [ -x /usr/libexec/PlistBuddy ]; then
        game_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || true)"
    fi

    if [ -z "$game_version" ]; then
        log "WARNING: Could not read the installed game version (runtime files target $target_version)"
    elif [ "$game_version" != "$target_version" ]; then
        log "WARNING: GAME VERSION MISMATCH: installed $game_version, runtime files target $target_version"
        log "WARNING: red4ext_hooks.js offsets and the address database may be unsafe for this build"
    else
        log "Game version $game_version matches the vendored runtime files"
    fi
}

validate_sources() {
    local source_root="$1"
    local source_label="$2"
    local rel=""
    local missing=0

    for rel in "${STATIC_FILES[@]}"; do
        if [ ! -f "$source_root/$rel" ]; then
            log "ERROR: Missing $source_label source: $rel"
            missing=$((missing + 1))
        fi
    done

    if [ "$missing" -ne 0 ]; then
        return 1
    fi
}

sync_file() {
    local source="$1"
    local destination="$2"
    local rel="$3"
    local destination_label="$4"

    if [ -f "$destination" ] && cmp -s "$source" "$destination"; then
        return
    fi

    if [ "$MODE" = "check" ]; then
        if [ -f "$destination" ]; then
            log "DIFFERS: $rel"
        else
            log "MISSING in $destination_label: $rel"
        fi
        difference_count=$((difference_count + 1))
        return
    fi

    mkdir -p "$(dirname "$destination")"
    if [ -f "$destination" ]; then
        cp -p "$source" "$destination"
        log "UPDATED: $rel"
    else
        cp -p "$source" "$destination"
        log "COPIED: $rel"
    fi
    changed_count=$((changed_count + 1))
}

sync_managed_files() {
    local source_root="$1"
    local destination_root="$2"
    local destination_label="$3"
    local rel=""

    for rel in "${STATIC_FILES[@]}"; do
        sync_file "$source_root/$rel" "$destination_root/$rel" "$rel" "$destination_label"
    done
}

log "=== Gamefiles sync start ($MODE) ==="
check_game_version

case "$MODE" in
    check)
        validate_sources "$GAMEFILES_DIR" "repository"
        sync_managed_files "$GAMEFILES_DIR" "$GAME_DIR" "game directory"
        if [ "$difference_count" -ne 0 ]; then
            log "CHECK FAILED: $difference_count difference(s) found"
            exit 1
        fi
        log "CHECK OK: game runtime files match the repository"
        ;;
    push)
        validate_sources "$GAMEFILES_DIR" "repository"
        sync_managed_files "$GAMEFILES_DIR" "$GAME_DIR" "game directory"
        log "Synced $changed_count file(s) from repository to game directory"
        ;;
    pull)
        validate_sources "$GAME_DIR" "game directory"
        sync_managed_files "$GAME_DIR" "$GAMEFILES_DIR" "repository"
        log "Synced $changed_count file(s) from game directory to repository"
        ;;
esac

log "=== Gamefiles sync complete ==="
