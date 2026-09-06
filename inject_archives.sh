#!/usr/bin/env bash
# Injects archive mods from enabled/ into the game. Safe to run standalone for testing.
# Restores pristine baseline first, then patches with enabled mods.
# Exit 0 = success (or no mods to inject), exit 1 = patch failed and pristine restored.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAME_DIR="${ARCHIVE_LOADER_GAME_DIR:-}"
if [ -z "$GAME_DIR" ]; then
    echo "ERROR: ARCHIVE_LOADER_GAME_DIR is not set. Export it to point at your Cyberpunk 2077 install." >&2
    echo "  e.g. export ARCHIVE_LOADER_GAME_DIR=\"/path/to/Cyberpunk 2077\"" >&2
    exit 1
fi
PRISTINE_DIR="$SCRIPT_DIR/pristine"
ENABLED_DIR="$SCRIPT_DIR/enabled"
PATCHER="$SCRIPT_DIR/bin/archive-loader"
LOG_DIR="$SCRIPT_DIR/logs"

mkdir -p "$LOG_DIR"
LOG_FILE="${INJECT_LOG_FILE:-$LOG_DIR/inject_$(date +%Y%m%d-%H%M%S).log}"

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }

# Restore pristine archives via APFS clone
restore_pristine() {
    local count=0
    for subdir in content ep1; do
        for f in "$PRISTINE_DIR/$subdir"/*.archive; do
            [ -f "$f" ] || continue
            cp -c "$f" "$GAME_DIR/archive/Mac/$subdir/$(basename "$f")"
            count=$((count + 1))
        done
    done
    find "$GAME_DIR/archive/Mac/content" -name "basegame_99_*" -type f -delete 2>/dev/null || true
    find "$GAME_DIR/archive/Mac/ep1" -name "basegame_99_*" -type f -delete 2>/dev/null || true
    rm -rf "$GAME_DIR/archive/Mac/mod" 2>/dev/null || true
    for backup_dir in \
        "$GAME_DIR/archive-loader/backups" \
        "$GAME_DIR/archive/Mac/_patcher" \
        "$GAME_DIR/archive/Mac/_cp2077_mac_patcher"; do
        [ -d "$backup_dir" ] || continue
        find "$backup_dir" -type d -empty -delete 2>/dev/null || true
    done
    log "Restored $count changed archives"
}

log "=== Archive injection start ==="

# Safety restore (handles prior crashes)
log "Restoring pristine baseline..."
restore_pristine

# Collect enabled mods
mod_files=()
if [ -d "$ENABLED_DIR" ]; then
    # LC_ALL=C is load-bearing: the patcher resolves conflicts in ASCII order
    # (Windows' first-archive-wins rule), while a bare `sort -z` under a UTF-8
    # locale weights punctuation loosely and orders the '#'-prefixed mods
    # differently. Without it the logged order is not the order that decides
    # which mod wins.
    while IFS= read -r -d '' f; do
        mod_files+=("$f")
    done < <(find "$ENABLED_DIR" -name "*.archive" -type f -print0 2>/dev/null | LC_ALL=C sort -z)
fi

if [ ${#mod_files[@]} -eq 0 ]; then
    log "No archive mods in enabled/, nothing to inject"
    exit 0
fi

log "Injecting ${#mod_files[@]} archive mods:"
for f in "${mod_files[@]}"; do
    log "  $(basename "$f")"
done

# Stage mods into game mod directory
mkdir -p "$GAME_DIR/archive/Mac/mod"
for f in "${mod_files[@]}"; do
    cp -c "$f" "$GAME_DIR/archive/Mac/mod/$(basename "$f")"
done

# Build patcher args
mods_args=()
for f in "${mod_files[@]}"; do
    mods_args+=("$GAME_DIR/archive/Mac/mod/$(basename "$f")")
done

# Patch
log "Running patcher..."
if "$PATCHER" patch --game "$GAME_DIR" --mods "${mods_args[@]}" 2>&1 | tee -a "$LOG_FILE"; then
    log "Patch successful"
    log "Verifying..."
    "$PATCHER" verify --game "$GAME_DIR" --mods "${mods_args[@]}" 2>&1 | tee -a "$LOG_FILE" || log "WARNING: verification reported issues"
    log "=== Archive injection complete ==="
    exit 0
else
    log "ERROR: Patcher failed, restoring pristine"
    restore_pristine
    log "=== Archive injection failed, game will launch vanilla ==="
    exit 1
fi
