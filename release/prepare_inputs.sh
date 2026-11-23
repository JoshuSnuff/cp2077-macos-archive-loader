#!/usr/bin/env bash
set -euo pipefail

SCRIPT_REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST_CONTRACT="$SCRIPT_REPOSITORY_DIR/release/manifest_contract.sh"
PROVENANCE_CONTRACT="$SCRIPT_REPOSITORY_DIR/release/provenance_contract.sh"
MANIFEST=""
OUTPUT_ROOT=""
PROVENANCE=""
VALIDATION_MODE=""
SOURCE_SPECS=()

usage() {
    cat <<EOF
Usage: $(basename "$0") --manifest MANIFEST --output-root DIR \
    --provenance PROVENANCE --source PACKAGE_PATH=SOURCE_FILE... \
    --production|--allow-synthetic

Stage exactly the manifest-declared package files into a fresh package root.
The target evidence file is read from PROVENANCE's directory as
target-evidence.json.
EOF
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

publish_staging_root() {
    local staging_root="$1"
    local output_root="$2"

    python3 - "$staging_root" "$output_root" <<'PY'
import ctypes
import errno
import os
import sys

source = os.fsencode(sys.argv[1])
destination = os.fsencode(sys.argv[2])
try:
    renamex_np = ctypes.CDLL(None, use_errno=True).renamex_np
except AttributeError:
    raise SystemExit("ERROR: macOS renamex_np is unavailable")

renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
renamex_np.restype = ctypes.c_int
if renamex_np(source, destination, 0x00000004) != 0:
    error = ctypes.get_errno()
    if error == errno.EEXIST:
        raise SystemExit("ERROR: output root changed before atomic publish")
    raise SystemExit(f"ERROR: atomic publish failed: {os.strerror(error)}")
PY
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --manifest)
            [ "$#" -ge 2 ] || fail "--manifest requires a value"
            MANIFEST="$2"
            shift 2
            ;;
        --output-root)
            [ "$#" -ge 2 ] || fail "--output-root requires a value"
            OUTPUT_ROOT="$2"
            shift 2
            ;;
        --provenance)
            [ "$#" -ge 2 ] || fail "--provenance requires a value"
            PROVENANCE="$2"
            shift 2
            ;;
        --source)
            [ "$#" -ge 2 ] || fail "--source requires PACKAGE_PATH=SOURCE_FILE"
            SOURCE_SPECS+=("$2")
            shift 2
            ;;
        --production)
            [ -z "$VALIDATION_MODE" ] || fail "choose exactly one validation mode"
            VALIDATION_MODE="production"
            shift
            ;;
        --allow-synthetic)
            [ -z "$VALIDATION_MODE" ] || fail "choose exactly one validation mode"
            VALIDATION_MODE="synthetic"
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
done

[ -n "$MANIFEST" ] || fail "--manifest is required"
[ -n "$OUTPUT_ROOT" ] || fail "--output-root is required"
[ -n "$PROVENANCE" ] || fail "--provenance is required"
[ -n "$VALIDATION_MODE" ] || fail "--production or --allow-synthetic is required"
[ -x "$MANIFEST_CONTRACT" ] || fail "manifest contract is unavailable: $MANIFEST_CONTRACT"
[ -x "$PROVENANCE_CONTRACT" ] || fail "provenance contract is unavailable: $PROVENANCE_CONTRACT"
[ -f "$MANIFEST" ] || fail "manifest is missing: $MANIFEST"
[ -f "$PROVENANCE" ] || fail "provenance is missing: $PROVENANCE"

# Validate the authoritative manifest before any output-root mutation.
"$MANIFEST_CONTRACT" validate "$MANIFEST"

python3 - "$MANIFEST" "${SOURCE_SPECS[@]}" <<'PY'
import json
import pathlib
import sys

manifest_path = pathlib.Path(sys.argv[1])
specs = sys.argv[2:]
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
expected = {entry["packagePath"] for entry in manifest["managedFiles"]}
mapped = {}

for spec in specs:
    if "=" not in spec:
        raise SystemExit(f"ERROR: source mapping must use PACKAGE_PATH=SOURCE_FILE: {spec}")
    package_path, source_name = spec.split("=", 1)
    if not package_path or not source_name:
        raise SystemExit(f"ERROR: source mapping is incomplete: {spec}")
    if package_path in mapped:
        raise SystemExit(f"ERROR: duplicate source mapping: {package_path}")
    if package_path not in expected:
        raise SystemExit(f"ERROR: source mapping is not declared by the manifest: {package_path}")
    source_path = pathlib.Path(source_name)
    if not source_path.is_file() or source_path.is_symlink():
        raise SystemExit(f"ERROR: source file is missing or is a symlink: {source_path}")
    mapped[package_path] = source_name

missing = sorted(expected - set(mapped))
if missing:
    raise SystemExit("ERROR: source mappings are missing: " + ", ".join(missing))
PY

OUTPUT_PARENT="$(dirname "$OUTPUT_ROOT")"
mkdir -p "$OUTPUT_PARENT"

STAGING_ROOT="$(mktemp -d "$OUTPUT_PARENT/.archive-loader-inputs.XXXXXX")"
OUTPUT_CLAIMED=0

# STAGING_ROOT is atomically created as a private cleanup root. Once the
# public output root is atomically claimed, it is never recursively deleted:
# a pathname can be replaced after any ownership check, so failures leave the
# claimed root intact rather than risking deletion of another owner's root.
cleanup() {
    # Test-only hook models a replacement at the former verification/deletion
    # boundary; production cleanup below remains private to STAGING_ROOT.
    if [ "${OUTPUT_CLAIMED:-0}" -eq 1 ] && [ -n "${ARCHIVE_LOADER_PREPARE_TEST_BEFORE_CLEANUP_HOOK:-}" ]; then
        "$ARCHIVE_LOADER_PREPARE_TEST_BEFORE_CLEANUP_HOOK" "$OUTPUT_ROOT"
    fi
    if [ -n "${STAGING_ROOT:-}" ] && [ -e "$STAGING_ROOT" ]; then
        rm -rf "$STAGING_ROOT"
    fi
}
trap cleanup EXIT

while IFS=$'\t' read -r package_path game_path expected_hash; do
    source_file=""
    for spec in "${SOURCE_SPECS[@]}"; do
        if [ "${spec%%=*}" = "$package_path" ]; then
            source_file="${spec#*=}"
            break
        fi
    done
    [ -n "$source_file" ] || fail "source mapping disappeared: $package_path"

    destination="$STAGING_ROOT/$package_path"
    mkdir -p "$(dirname "$destination")"
    cp "$source_file" "$destination"

    case "$package_path" in
        archive-loader/bin/archive-loader|archive-loader/setup.command)
            chmod 0755 "$destination"
            ;;
        *)
            chmod 0644 "$destination"
            ;;
    esac

    actual_hash="$("$MANIFEST_CONTRACT" file-hash "$MANIFEST" "$destination" "$package_path" "$game_path")"
    [ "$actual_hash" = "$expected_hash" ] || fail "staged hash mismatch: $package_path"
done < <("$MANIFEST_CONTRACT" records "$MANIFEST")

if mkdir "$OUTPUT_ROOT" 2>/dev/null; then
    OUTPUT_CLAIMED=1
else
    if [ -e "$OUTPUT_ROOT" ] || [ -L "$OUTPUT_ROOT" ]; then
        fail "output root already exists: $OUTPUT_ROOT"
    fi
    fail "could not claim output root: $OUTPUT_ROOT"
fi
# Release the empty claim before publishing the complete private tree. The
# no-replace rename below handles any destination that appears in this gap.
rmdir "$OUTPUT_ROOT" || fail "output root changed before atomic publish: $OUTPUT_ROOT"
if [ -n "${ARCHIVE_LOADER_PREPARE_TEST_AFTER_CLAIM_HOOK:-}" ]; then
    "$ARCHIVE_LOADER_PREPARE_TEST_AFTER_CLAIM_HOOK" "$OUTPUT_ROOT"
fi
publish_staging_root "$STAGING_ROOT" "$OUTPUT_ROOT"
STAGING_ROOT=""

# Validate the final root, including exact declared-file coverage, before
# handing it to the existing provenance contract.
"$MANIFEST_CONTRACT" validate "$MANIFEST" "$OUTPUT_ROOT"
TARGET_EVIDENCE="$(dirname "$PROVENANCE")/target-evidence.json"
[ -f "$TARGET_EVIDENCE" ] || fail "target evidence is missing: $TARGET_EVIDENCE"

if [ "$VALIDATION_MODE" = "synthetic" ]; then
    ARCHIVE_LOADER_ALLOW_SYNTHETIC=1 "$PROVENANCE_CONTRACT" validate \
        "$PROVENANCE" "$MANIFEST" "$OUTPUT_ROOT" "$TARGET_EVIDENCE"
else
    ARCHIVE_LOADER_ALLOW_SYNTHETIC=0 "$PROVENANCE_CONTRACT" validate \
        "$PROVENANCE" "$MANIFEST" "$OUTPUT_ROOT" "$TARGET_EVIDENCE"
fi

OUTPUT_CLAIMED=0
trap - EXIT
echo "$OUTPUT_ROOT"
