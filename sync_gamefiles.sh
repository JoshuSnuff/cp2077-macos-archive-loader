#!/usr/bin/env bash
# Synchronizes the tracked RED4ext runtime files with the game installation.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_DIR="${ARCHIVE_LOADER_REPOSITORY_DIR:-$SCRIPT_DIR}"
PACKAGE_ROOT="${ARCHIVE_LOADER_PACKAGE_ROOT:-$REPOSITORY_DIR}"
MANIFEST_CONTRACT="$SCRIPT_DIR/release/manifest_contract.sh"
COMPATIBILITY_MANIFEST="${ARCHIVE_LOADER_MANIFEST:-$REPOSITORY_DIR/compatibility/manifest.json}"
GAME_DIR="${ARCHIVE_LOADER_GAME_DIR:-}"
LOG_DIR="$REPOSITORY_DIR/logs"
MODE="push"
RESTORE_SNAPSHOT_ID=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [--check | --pull | --restore-snapshot ID]

  no option  Copy managed files from this repository to the game directory.
  --check    Report differences without changing files; exit 1 if any differ.
  --pull     Stage observed game files outside this repository for review.
  --restore-snapshot ID  Restore a retained push snapshot.
EOF
}

if [ "$#" -gt 2 ]; then usage >&2; exit 2; fi
if [ "$#" -ge 1 ]; then
    case "$1" in
        --check) MODE="check" ;;
        --pull) MODE="pull" ;;
        --restore-snapshot)
            [ "$#" -eq 2 ] || { usage >&2; exit 2; }
            MODE="restore"; RESTORE_SNAPSHOT_ID="$2" ;;
        --help|-h) usage; exit 0 ;;
        *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
fi

if [ -z "$GAME_DIR" ]; then
    echo "ERROR: ARCHIVE_LOADER_GAME_DIR is not set. Export it to point at your Cyberpunk 2077 install." >&2
    exit 1
fi
if [ ! -d "$GAME_DIR" ]; then echo "ERROR: game directory does not exist: $GAME_DIR" >&2; exit 1; fi
if [ ! -f "$COMPATIBILITY_MANIFEST" ]; then
    echo "ERROR: compatibility/manifest.json is missing; refusing to synchronize runtime files" >&2
    exit 1
fi

mkdir -p "$LOG_DIR"
LOG_FILE="${SYNC_LOG_FILE:-$LOG_DIR/sync_$(date +%Y%m%d-%H%M%S).log}"
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }

changed_count=0
difference_count=0
snapshot_id="$(python3 -c 'import uuid; print(uuid.uuid4())')"

manifest_records() {
    bash "$MANIFEST_CONTRACT" records "$COMPATIBILITY_MANIFEST"
}

validate_identity() {
    local plist="$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
    local gog="$GAME_DIR/Contents/Resources/goggame-1423049311.info"
    local executable="$GAME_DIR/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
    [ -f "$plist" ] && [ -f "$gog" ] && [ -f "$executable" ] || {
        log "ERROR: authoritative game identity inputs are incomplete"; return 1;
    }
    local version bundle build
    version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null)"
    bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null)"
    build="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["buildId"])' "$gog")"
    [ "$version" = "2.5.0" ] && [ "$bundle" = "5814786" ] && [ "$build" = "60152051833789151" ] || {
        log "ERROR: game identity does not match the compatibility manifest"; return 1;
    }
    local architecture uuid digest
    architecture="$(lipo -archs "$executable" 2>/dev/null)"
    uuid="$(otool -arch arm64 -l "$executable" 2>/dev/null | awk '$1 == "uuid" {print tolower($2); exit}')"
    digest="$(shasum -a 256 "$executable" | awk '{print $1}')"
    case " $architecture " in *" arm64 "*) ;; *) log "ERROR: executable has no arm64 slice"; return 1 ;; esac
    local expected
    expected="$(python3 - "$COMPATIBILITY_MANIFEST" <<'PY'
import json, sys
m=json.load(open(sys.argv[1]))
e=m["target"]["executable"]
print(e["uuid"], e["sha256"])
PY
)"
    [ "$uuid" = "${expected%% *}" ] && [ "$digest" = "${expected##* }" ] || {
        log "ERROR: executable UUID or SHA-256 does not match the manifest"; return 1;
    }
}

validate_sources() {
    local source_root="$1" package_path game_path expected actual
    while IFS=$'\t' read -r package_path game_path expected; do
        [ -n "$package_path" ] || continue
        if [ "$MODE" = pull ]; then
            [ -f "$source_root/$game_path" ] || continue
        else
            [ -f "$source_root/$package_path" ] || { log "ERROR: Missing package source: $package_path"; return 1; }
            actual="$(bash "$MANIFEST_CONTRACT" file-hash "$COMPATIBILITY_MANIFEST" "$source_root/$package_path" "$package_path" "$game_path")"
            [ "$actual" = "$expected" ] || { log "ERROR: source hash mismatch: $package_path"; return 1; }
        fi
    done < <(manifest_records)
}

write_transaction_marker() {
    local transaction_id="$1" phase="$2"
    local marker_dir="$GAME_DIR/archive-loader/state/install-transactions"
    local marker="$marker_dir/$transaction_id.json"
    local temporary="$marker.tmp"
    mkdir -p "$marker_dir"
    jq -n \
        --arg transactionID "$transaction_id" \
        --arg phase "$phase" \
        --arg snapshotPath "archive-loader/state/install-snapshots/$transaction_id" \
        --arg stagingPath "archive-loader/state/install-staging/$transaction_id" \
        '{transactionID: $transactionID, phase: $phase,
          snapshotPath: $snapshotPath, stagingPath: $stagingPath}' > "$temporary"
    mv -f "$temporary" "$marker"
}

restore_snapshot() {
    local transaction_id="$1"
    local snapshot_root="$GAME_DIR/archive-loader/state/install-snapshots/$transaction_id"
    local snapshot="$snapshot_root/snapshot.json"
    local game_path present expected mode actual destination temporary
    case "$transaction_id" in
        ""|*[!A-Za-z0-9._-]*) log "ERROR: invalid snapshot id: $transaction_id"; return 1 ;;
    esac
    [ -f "$snapshot" ] || { log "ERROR: snapshot not found: $transaction_id"; return 1; }
    jq -e --arg id "$transaction_id" \
        '.transactionID == $id and .complete == true' "$snapshot" >/dev/null || {
        log "ERROR: snapshot record is incomplete: $transaction_id"; return 1;
    }
    while IFS=$'\t' read -r game_path present expected mode; do
        destination="$GAME_DIR/$game_path"
        if [ "$present" = true ]; then
            [ -f "$snapshot_root/files/$game_path" ] || {
                log "ERROR: snapshot file is missing: $game_path"; return 1;
            }
            actual="$(shasum -a 256 "$snapshot_root/files/$game_path" | awk '{print $1}')"
            [ "$actual" = "$expected" ] || {
                log "ERROR: snapshot hash mismatch: $game_path"; return 1;
            }
            mkdir -p "$(dirname "$destination")"
            temporary="$destination.archive-loader-restore-$transaction_id.tmp"
            cp -p "$snapshot_root/files/$game_path" "$temporary"
            chmod "$mode" "$temporary"
            mv -f "$temporary" "$destination"
        else
            rm -f "$destination"
        fi
    done < <(jq -r '.managed[] | [.gamePath, (.present|tostring), (.sha256 // ""), (.mode // "")] | @tsv' "$snapshot")

    while IFS=$'\t' read -r game_path present expected; do
        destination="$GAME_DIR/$game_path"
        if [ "$present" = true ]; then
            [ -f "$destination" ] || { log "ERROR: restored file is missing: $game_path"; return 1; }
            actual="$(shasum -a 256 "$destination" | awk '{print $1}')"
            [ "$actual" = "$expected" ] || { log "ERROR: restored hash mismatch: $game_path"; return 1; }
        elif [ -e "$destination" ]; then
            log "ERROR: restore did not remove originally absent path: $game_path"
            return 1
        fi
    done < <(jq -r '.managed[] | [.gamePath, (.present|tostring), (.sha256 // "")] | @tsv' "$snapshot")
    write_transaction_marker "$transaction_id" "rolled-back"
    log "SNAPSHOT_RESTORED: $transaction_id"
}

sync_file() {
    local source="$1" destination="$2" rel="$3" destination_label="$4"
    if [ -f "$destination" ] && cmp -s "$source" "$destination"; then return; fi
    if [ "$MODE" = check ]; then
        if [ -f "$destination" ]; then
            log "DIFFERS: $rel"
        else
            log "MISSING in $destination_label: $rel"
        fi
        difference_count=$((difference_count + 1)); return
    fi
    mkdir -p "$(dirname "$destination")"
    cp -p "$source" "$destination"
    if [ "$MODE" = pull ]; then
        log "STAGED: $rel"
    else
        log "COPIED: $rel"
    fi
    changed_count=$((changed_count + 1))
}

sync_managed_files() {
    local source_root="$1" destination_root="$2" destination_label="$3"
    local package_path game_path expected source destination replacement_count=0
    while IFS=$'\t' read -r package_path game_path expected; do
        [ -n "$package_path" ] || continue
        if [ "$MODE" = pull ]; then source="$source_root/$game_path"; destination="$destination_root/files/$game_path"; else source="$source_root/$package_path"; destination="$destination_root/$game_path"; fi
        [ -f "$source" ] || continue
        sync_file "$source" "$destination" "$game_path" "$destination_label"
        if [ "$MODE" = push ]; then
            replacement_count=$((replacement_count + 1))
            if [ "${ARCHIVE_LOADER_SYNC_FAIL_AFTER_REPLACEMENTS:-0}" -eq "$replacement_count" ]; then
                return 1
            fi
        fi
    done < <(manifest_records)
}

create_snapshot() {
    local transaction_id="$1"
    local snapshot_root="$GAME_DIR/archive-loader/state/install-snapshots/$transaction_id"
    local package_path game_path expected
    mkdir -p "$snapshot_root/files"
    while IFS=$'\t' read -r package_path game_path expected; do
        [ -n "$package_path" ] || continue
        if [ -f "$GAME_DIR/$game_path" ]; then
            mkdir -p "$snapshot_root/files/$(dirname "$game_path")"
            cp -p "$GAME_DIR/$game_path" "$snapshot_root/files/$game_path"
        elif [ -e "$GAME_DIR/$game_path" ]; then
            log "ERROR: managed destination is not a regular file: $game_path"
            return 1
        fi
    done < <(manifest_records)
    python3 - "$snapshot_root" "$GAME_DIR" "$COMPATIBILITY_MANIFEST" "$transaction_id" <<'PY'
import hashlib
import json
import pathlib
import sys

snapshot, game, manifest = map(pathlib.Path, sys.argv[1:4])
transaction_id = sys.argv[4]
managed = []
for entry in json.loads(manifest.read_text(encoding="utf-8"))["managedFiles"]:
    path = entry["gamePath"]
    original = game / path
    copied = snapshot / "files" / path
    present = copied.is_file()
    managed.append({
        "packagePath": entry["packagePath"],
        "gamePath": path,
        "present": present,
        "sha256": hashlib.sha256(copied.read_bytes()).hexdigest() if present else None,
        "mode": format(original.stat().st_mode & 0o7777, "o") if present else None,
    })
record = {
    "transactionID": transaction_id,
    "complete": True,
    "managed": managed,
}
temporary = snapshot / "snapshot.json.tmp"
temporary.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
temporary.replace(snapshot / "snapshot.json")
PY
    log "SNAPSHOT_CREATED: $transaction_id"
}

stage_sources() {
    local transaction_id="$1"
    local staging_root="$GAME_DIR/archive-loader/state/install-staging/$transaction_id"
    local package_path game_path expected source staged actual
    mkdir -p "$staging_root/files"
    while IFS=$'\t' read -r package_path game_path expected; do
        [ -n "$package_path" ] || continue
        source="$PACKAGE_ROOT/$package_path"
        staged="$staging_root/files/$game_path"
        mkdir -p "$(dirname "$staged")"
        cp -p "$source" "$staged"
        actual="$(bash "$MANIFEST_CONTRACT" file-hash "$COMPATIBILITY_MANIFEST" "$staged" "$package_path" "$game_path")"
        [ "$actual" = "$expected" ] || { log "ERROR: staged hash mismatch: $game_path"; return 1; }
    done < <(manifest_records)
}

replace_staged_files() {
    local transaction_id="$1"
    local staging_root="$GAME_DIR/archive-loader/state/install-staging/$transaction_id"
    local package_path game_path expected source destination temporary replacement_count=0
    local fail_after="${ARCHIVE_LOADER_SYNC_FAIL_AFTER_REPLACEMENTS:-0}"
    case "$fail_after" in
        *[!0-9]*) log "ERROR: ARCHIVE_LOADER_SYNC_FAIL_AFTER_REPLACEMENTS must be numeric"; return 1 ;;
    esac
    while IFS=$'\t' read -r package_path game_path expected; do
        [ -n "$package_path" ] || continue
        source="$staging_root/files/$game_path"
        destination="$GAME_DIR/$game_path"
        mkdir -p "$(dirname "$destination")"
        temporary="$destination.archive-loader-$transaction_id.tmp"
        cp -p "$source" "$temporary" || return 1
        mv -f "$temporary" "$destination" || return 1
        replacement_count=$((replacement_count + 1))
        if [ "$fail_after" -gt 0 ] && [ "$replacement_count" -eq "$fail_after" ]; then
            log "ERROR: injected failure after $replacement_count replacement(s)"
            return 1
        fi
    done < <(manifest_records)
}

verify_installed_files() {
    local package_path game_path expected destination actual
    while IFS=$'\t' read -r package_path game_path expected; do
        [ -n "$package_path" ] || continue
        destination="$GAME_DIR/$game_path"
        [ -f "$destination" ] || { log "ERROR: installed file is missing: $game_path"; return 1; }
        actual="$(bash "$MANIFEST_CONTRACT" file-hash "$COMPATIBILITY_MANIFEST" "$destination" "$package_path" "$game_path")"
        [ "$actual" = "$expected" ] || { log "ERROR: installed hash mismatch: $game_path"; return 1; }
    done < <(manifest_records)
}

check_installed_files() {
    local package_path game_path expected destination actual differences=0
    while IFS=$'\t' read -r package_path game_path expected; do
        [ -n "$package_path" ] || continue
        destination="$GAME_DIR/$game_path"
        if [ ! -f "$destination" ]; then
            log "MISSING in game directory: $game_path"
            differences=$((differences + 1))
        elif ! actual="$(bash "$MANIFEST_CONTRACT" file-hash "$COMPATIBILITY_MANIFEST" "$destination" "$package_path" "$game_path" 2>/dev/null)" ||
            [ "$actual" != "$expected" ]; then
            log "DIFFERS: $game_path"
            differences=$((differences + 1))
        fi
    done < <(manifest_records)
    if [ "$differences" -ne 0 ]; then
        log "CHECK FAILED: $differences difference(s) found"
        return 1
    fi
    log "CHECK OK: all manifest-declared game files match"
}

write_pull_record() {
    local pull_root="$1"
    local entries="$pull_root/.pull-record.jsonl"
    local package_path game_path expected source observed comparison status
    : > "$entries"
    while IFS=$'\t' read -r package_path game_path expected; do
        [ -n "$package_path" ] || continue
        source="$GAME_DIR/$game_path"
        if [ -f "$source" ]; then
            observed="$(shasum -a 256 "$source" | awk '{print $1}')"
            status="drifted"
            if comparison="$(bash "$MANIFEST_CONTRACT" file-hash "$COMPATIBILITY_MANIFEST" "$source" "$package_path" "$game_path" 2>/dev/null)" &&
                [ "$comparison" = "$expected" ]; then
                status="matching"
            fi
            jq -cn \
                --arg packagePath "$package_path" \
                --arg gamePath "$game_path" \
                --arg observedSha256 "$observed" \
                --arg manifestSha256 "$expected" \
                --arg status "$status" \
                '{packagePath: $packagePath, gamePath: $gamePath,
                  observedSha256: $observedSha256, manifestSha256: $manifestSha256,
                  status: $status, missing: false}' >> "$entries"
        else
            jq -cn \
                --arg packagePath "$package_path" \
                --arg gamePath "$game_path" \
                --arg manifestSha256 "$expected" \
                '{packagePath: $packagePath, gamePath: $gamePath,
                  observedSha256: null, manifestSha256: $manifestSha256,
                  status: "missing", missing: true}' >> "$entries"
        fi
    done < <(manifest_records)
    jq -s --arg transactionID "$snapshot_id" \
        '{transactionID: $transactionID, managed: .}' "$entries" > "$pull_root/pull-record.json"
    rm -f "$entries"
}

validate_external_pull_root() {
    local pull_root="$1"
    if ! python3 - "$REPOSITORY_DIR" "$pull_root" <<'PY'
import pathlib
import sys

repository = pathlib.Path(sys.argv[1]).resolve()
staging = pathlib.Path(sys.argv[2]).resolve()
if staging == repository or repository in staging.parents:
    raise SystemExit(1)
PY
    then
        log "ERROR: ARCHIVE_LOADER_PULL_STAGING must be outside the repository: $pull_root"
        return 1
    fi
}

log "=== Gamefiles sync start ($MODE) ==="
bash "$MANIFEST_CONTRACT" validate "$COMPATIBILITY_MANIFEST"
validate_identity
case "$MODE" in
    restore)
        validate_sources "$PACKAGE_ROOT" repository
        restore_snapshot "$RESTORE_SNAPSHOT_ID" ;;
    check)
        check_installed_files ;;
    push)
        validate_sources "$PACKAGE_ROOT" repository
        snapshot_root="$GAME_DIR/archive-loader/state/install-snapshots/$snapshot_id"
        staging_root="$GAME_DIR/archive-loader/state/install-staging/$snapshot_id"
        write_transaction_marker "$snapshot_id" "prepared"
        if ! create_snapshot "$snapshot_id" ||
            ! stage_sources "$snapshot_id"; then
            log "FATAL: transaction preparation failed; retained state for recovery: $snapshot_id"
            exit 1
        fi
        write_transaction_marker "$snapshot_id" "staged"
        write_transaction_marker "$snapshot_id" "replacing"
        if ! replace_staged_files "$snapshot_id" || ! verify_installed_files; then
            if ! restore_snapshot "$snapshot_id"; then
                log "FATAL: rollback failed; retained transaction state for recovery: $snapshot_id"
            fi
            exit 1
        fi
        write_transaction_marker "$snapshot_id" "committed"
        rm -rf "$staging_root"
        log "TRANSACTION_COMMITTED: $snapshot_id"
        log "Synced manifest-declared files from package to game directory" ;;
    pull)
        pull_root="${ARCHIVE_LOADER_PULL_STAGING:-$(dirname "$REPOSITORY_DIR")/.archive-loader-pull-staging}/$snapshot_id"
        validate_external_pull_root "$pull_root"
        mkdir -p "$pull_root"
        sync_managed_files "$GAME_DIR" "$pull_root" "pull staging"
        write_pull_record "$pull_root"
        log "PULL_STAGED: $pull_root"
        log "Pull staged under $pull_root; canonical repository files were not modified" ;;
esac
log "=== Gamefiles sync complete ==="
