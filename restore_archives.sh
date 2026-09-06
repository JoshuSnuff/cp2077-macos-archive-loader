#!/usr/bin/env bash
# Restores pristine official archives via APFS clone. Safe to run standalone.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAME_DIR="${ARCHIVE_LOADER_GAME_DIR:-}"
if [ -z "$GAME_DIR" ]; then
    echo "ERROR: ARCHIVE_LOADER_GAME_DIR is not set. Export it to point at your Cyberpunk 2077 install." >&2
    echo "  e.g. export ARCHIVE_LOADER_GAME_DIR=\"/path/to/Cyberpunk 2077\"" >&2
    exit 1
fi
PRISTINE_DIR="$SCRIPT_DIR/pristine"
LOG_DIR="$SCRIPT_DIR/logs"

mkdir -p "$LOG_DIR"
LOG_FILE="${RESTORE_LOG_FILE:-$LOG_DIR/restore_$(date +%Y%m%d-%H%M%S).log}"

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }

log "=== Archive restoration start ==="

count=0
for subdir in content ep1; do
    for f in "$PRISTINE_DIR/$subdir"/*.archive; do
        [ -f "$f" ] || continue
        cp -c "$f" "$GAME_DIR/archive/Mac/$subdir/$(basename "$f")"
        count=$((count + 1))
    done
done

# Remove patcher-generated loose archives (basegame_99_*)
loose=0
for pat in "$GAME_DIR/archive/Mac/content/basegame_99_"* "$GAME_DIR/archive/Mac/ep1/basegame_99_"*; do
    [ -f "$pat" ] || continue
    rm "$pat"
    loose=$((loose + 1))
done

# Clear mod staging area
if [ -d "$GAME_DIR/archive/Mac/mod" ]; then
    find "$GAME_DIR/archive/Mac/mod" -name "*.archive" -type f -delete 2>/dev/null || true
    rmdir "$GAME_DIR/archive/Mac/mod" 2>/dev/null || true
fi

# Clear patcher backups created during this session. archive-loader/backups is
# where 0.1 writes them; the archive/Mac paths are pre-0.1 locations, cleaned
# here so an install that predates the move does not keep them forever.
for backup_dir in \
    "$GAME_DIR/archive-loader/backups" \
    "$GAME_DIR/archive/Mac/_patcher" \
    "$GAME_DIR/archive/Mac/_cp2077_mac_patcher"; do
    if [ -d "$backup_dir" ]; then
        find "$backup_dir" -type f -delete 2>/dev/null || true
        find "$backup_dir" -type d -empty -delete 2>/dev/null || true
    fi
done

log "Restored $count archives, removed $loose loose files"
log "=== Archive restoration complete ==="
