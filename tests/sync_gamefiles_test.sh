#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC_SCRIPT="$REPOSITORY_DIR/sync_gamefiles.sh"
FIXTURE_HELPER="$REPOSITORY_DIR/tests/fixtures/release-inputs/synthetic/create_fixture.sh"
WORK_DIR="$(mktemp -d /private/tmp/archive-loader-sync-test.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() { echo "ERROR: $1" >&2; exit 1; }

FIXTURE_ROOT="$WORK_DIR/fixture repository"
"$FIXTURE_HELPER" "$FIXTURE_ROOT" "0.1.3"
PACKAGE_ROOT="$FIXTURE_ROOT/package"
MANIFEST="$PACKAGE_ROOT/archive-loader/compatibility/manifest.json"
GAME_DIR="$FIXTURE_ROOT/Cyberpunk 2077"
STUB_DIR="$FIXTURE_ROOT/stubs"
PULL_ROOT="$WORK_DIR/external pull staging"
LOG_FILE="$WORK_DIR/sync.log"

run_sync() {
    ARCHIVE_LOADER_REPOSITORY_DIR="$FIXTURE_ROOT" \
    ARCHIVE_LOADER_PACKAGE_ROOT="$PACKAGE_ROOT" \
    ARCHIVE_LOADER_MANIFEST="$MANIFEST" \
    ARCHIVE_LOADER_GAME_DIR="$GAME_DIR" \
    ARCHIVE_LOADER_PULL_STAGING="${ARCHIVE_LOADER_PULL_STAGING:-$PULL_ROOT}" \
    SYNC_LOG_FILE="$LOG_FILE" \
    PATH="$STUB_DIR:$PATH" \
        "$SYNC_SCRIPT" "$@"
}

runtime_package="$PACKAGE_ROOT/archive-loader/red4ext/runtime.txt"
runtime_game="$GAME_DIR/red4ext/runtime.txt"
absent_game="$GAME_DIR/red4ext/absent.txt"
loader_game="$GAME_DIR/archive-loader/bin/archive-loader"

if run_sync --check >/dev/null 2>&1; then fail "check passed before managed files were installed"; fi
[ ! -e "$GAME_DIR/archive-loader/state" ] || fail "check wrote transaction state"

valid_manifest="$WORK_DIR/manifest.valid.json"
cp "$MANIFEST" "$valid_manifest"
printf ' ' >> "$MANIFEST"
if self_hash_output="$(run_sync 2>&1)"; then
    fail "push accepted a manifest with a stale exact-byte self-hash"
fi
case "$self_hash_output" in
    *"manifest self-hash mismatch"*) ;;
    *) fail "push did not report the exact-byte self-hash failure" ;;
esac
[ ! -e "$runtime_game" ] || fail "self-hash failure wrote a managed file"
[ ! -e "$GAME_DIR/archive-loader/state" ] || fail "self-hash failure created transaction state"
cp "$valid_manifest" "$MANIFEST"

printf '\377' >> "$MANIFEST"
if utf8_output="$(run_sync 2>&1)"; then
    fail "push accepted a non-UTF-8 manifest"
fi
case "$utf8_output" in
    *"cannot read UTF-8 manifest"*) ;;
    *) fail "push did not report the UTF-8 manifest failure" ;;
esac
[ ! -e "$runtime_game" ] || fail "UTF-8 failure wrote a managed file"
[ ! -e "$GAME_DIR/archive-loader/state" ] || fail "UTF-8 failure created transaction state"
cp "$valid_manifest" "$MANIFEST"

metadata="$GAME_DIR/Contents/Resources/goggame-1423049311.info"
cp "$metadata" "$GAME_DIR/goggame-1423049311.info"
mv "$metadata" "$WORK_DIR/resources-gog.info"
if run_sync >/dev/null 2>&1; then fail "push accepted root-level GOG metadata"; fi
[ ! -e "$runtime_game" ] || fail "identity failure wrote a managed file"
mv "$WORK_DIR/resources-gog.info" "$metadata"

printf 'tampered package bytes\n' > "$runtime_package"
if run_sync >/dev/null 2>&1; then fail "push accepted a source hash mismatch"; fi
[ ! -e "$runtime_game" ] || fail "source hash failure wrote a managed file"
[ ! -e "$GAME_DIR/archive-loader/state" ] || fail "source hash failure created transaction state"
printf 'synthetic repository runtime\n' > "$runtime_package"

run_sync >/dev/null || fail "manifest-driven push failed"
[ "$(cat "$runtime_game")" = "synthetic repository runtime" ] || fail "push did not use the exact manifest mapping"
[ -x "$GAME_DIR/archive-loader/bin/archive-loader" ] || fail "push did not preserve executable mode"
run_sync --check >/dev/null || fail "check failed after a matching push"

transaction_id="$(sed -n 's/.*TRANSACTION_COMMITTED: //p' "$LOG_FILE" | tail -n 1)"
[ -n "$transaction_id" ] || fail "push did not report a committed transaction"
snapshot_dir="$GAME_DIR/archive-loader/state/install-snapshots/$transaction_id"
marker="$GAME_DIR/archive-loader/state/sync-transactions/$transaction_id.json"
[ -f "$snapshot_dir/snapshot.json" ] || fail "push did not create a snapshot record"
[ "$(jq -r --arg path 'red4ext/absent.txt' '.managed[] | select(.gamePath == $path) | .present' "$snapshot_dir/snapshot.json")" = "false" ] \
    || fail "snapshot did not record an absent destination"
[ "$(jq -r '.phase' "$marker")" = "committed" ] || fail "transaction was not committed"

package_before="$(shasum -a 256 "$runtime_package" | awk '{print $1}')"
manifest_before="$(shasum -a 256 "$MANIFEST" | awk '{print $1}')"
printf 'drift observed in game\n' > "$runtime_game"
rm -f "$absent_game"
in_repository_pull="$FIXTURE_ROOT/pull staging"
if ARCHIVE_LOADER_PULL_STAGING="$in_repository_pull" run_sync --pull >/dev/null 2>&1; then
    fail "pull accepted a staging root inside the repository"
fi
[ ! -e "$in_repository_pull" ] || fail "rejected in-repository pull created staging files"
pull_output="$(run_sync --pull)" || fail "manifest-driven pull failed"
staging_dir="$(printf '%s\n' "$pull_output" | sed -n 's/.*PULL_STAGED: //p' | tail -n 1)"
[ -n "$staging_dir" ] || fail "pull did not report staging directory"
case "$staging_dir" in "$PULL_ROOT"/*) ;; *) fail "pull staging escaped configured root" ;; esac
[ "$(shasum -a 256 "$runtime_package" | awk '{print $1}')" = "$package_before" ] || fail "pull overwrote canonical package bytes"
[ "$(shasum -a 256 "$MANIFEST" | awk '{print $1}')" = "$manifest_before" ] || fail "pull overwrote canonical manifest bytes"
[ "$(cat "$staging_dir/files/red4ext/runtime.txt")" = "drift observed in game" ] || fail "pull did not stage observed bytes"
[ "$(jq -r --arg path 'red4ext/runtime.txt' '.managed[] | select(.gamePath == $path) | .status' "$staging_dir/pull-record.json")" = "drifted" ] \
    || fail "pull did not record drift"
[ "$(jq -r --arg path 'red4ext/absent.txt' '.managed[] | select(.gamePath == $path) | .status' "$staging_dir/pull-record.json")" = "missing" ] \
    || fail "pull did not record missing path"

printf 'pre-rollback game bytes\n' > "$runtime_game"
printf 'pre-rollback loader bytes\n' > "$loader_game"
chmod +x "$loader_game"
rm -f "$absent_game"
if ARCHIVE_LOADER_SYNC_FAIL_AFTER_REPLACEMENTS=1 run_sync >/dev/null 2>&1; then fail "injected replacement failure reported success"; fi
[ "$(cat "$loader_game")" = "pre-rollback loader bytes" ] || fail "rollback did not restore the first replaced file"
[ "$(cat "$runtime_game")" = "pre-rollback game bytes" ] || fail "rollback did not restore present bytes"
[ ! -e "$absent_game" ] || fail "rollback did not restore absent path"
rolled_back_marker="$(find "$GAME_DIR/archive-loader/state/sync-transactions" -name '*.json' -type f -print0 \
    | xargs -0 grep -l '"phase": "rolled-back"' | tail -n 1)"
[ -n "$rolled_back_marker" ] || fail "failure did not retain rolled-back marker"

printf 'changed after snapshot\n' > "$runtime_game"
printf 'should disappear\n' > "$absent_game"
run_sync --restore-snapshot "$transaction_id" >/dev/null || fail "explicit snapshot restore failed"
[ ! -e "$runtime_game" ] || fail "restore did not recover originally absent runtime"
[ ! -e "$absent_game" ] || fail "restore did not remove originally absent file"

echo "sync gamefiles test passed"
