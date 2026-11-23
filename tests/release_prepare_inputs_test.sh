#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREPARE="$REPOSITORY_DIR/release/prepare_inputs.sh"
MANIFEST_CONTRACT="$REPOSITORY_DIR/release/manifest_contract.sh"
FIXTURE_HELPER="$REPOSITORY_DIR/tests/fixtures/release-inputs/synthetic/create_fixture.sh"
WORK_DIR="$(mktemp -d /private/tmp/archive-loader-prepare-inputs-test.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

if [ ! -x "$PREPARE" ]; then
    echo "ERROR: missing prepare command: $PREPARE" >&2
    exit 1
fi

FIXTURE_ROOT="$WORK_DIR/synthetic fixture"
SOURCE_ROOT="$WORK_DIR/external source directory"
"$FIXTURE_HELPER" "$FIXTURE_ROOT" "0.1.3"
mkdir -p "$SOURCE_ROOT"
cp -R "$FIXTURE_ROOT/package/." "$SOURCE_ROOT/"
printf 'unrelated vendor file\n' > "$SOURCE_ROOT/unrelated-vendor-file.txt"

MANIFEST="$FIXTURE_ROOT/package/archive-loader/compatibility/manifest.json"
PROVENANCE="$FIXTURE_ROOT/evidence/provenance.json"
TARGET_EVIDENCE="$FIXTURE_ROOT/evidence/target-evidence.json"
SOURCE_ARGS=()
while IFS=$'\t' read -r package_path game_path expected_hash; do
    SOURCE_ARGS+=(--source "$package_path=$SOURCE_ROOT/$package_path")
done < <("$MANIFEST_CONTRACT" records "$MANIFEST")

run_prepare() {
    local output_root="$1"
    shift
    "$PREPARE" \
        --manifest "$MANIFEST" \
        --output-root "$output_root" \
        --provenance "$PROVENANCE" \
        "$@"
}

expect_failure() {
    local label="$1"
    shift
    if run_prepare "$@"; then
        echo "ERROR: $label was accepted" >&2
        exit 1
    fi
}

expect_synthetic_success() {
    local output_root="$1"
    shift
    run_prepare "$output_root" "$@" --allow-synthetic
}

assert_external_replacement_root() {
    local replacement_root="$1"
    python3 - "$replacement_root" <<'PY'
import pathlib
import sys

replacement_root = pathlib.Path(sys.argv[1])
if not replacement_root.is_dir() or replacement_root.is_symlink():
    raise SystemExit(f"ERROR: replacement root is not a directory: {replacement_root}")

entries = sorted(path.relative_to(replacement_root).as_posix() for path in replacement_root.rglob("*"))
if entries != ["external-sentinel"]:
    raise SystemExit(f"ERROR: replacement contains unexpected entries: {entries!r}")

sentinel = replacement_root / "external-sentinel"
if sentinel.is_symlink() or not sentinel.is_file():
    raise SystemExit("ERROR: replacement sentinel is not a regular file")
if sentinel.read_bytes() != b"external sentinel\n":
    raise SystemExit("ERROR: replacement sentinel bytes were altered")
PY
}

MISSING_ARGS=("${SOURCE_ARGS[@]:0:${#SOURCE_ARGS[@]}-2}")
expect_failure "missing source mapping" "$WORK_DIR/missing-output" "${MISSING_ARGS[@]}" --allow-synthetic

DUPLICATE_ARGS=(
    "${SOURCE_ARGS[@]}"
    --source "archive-loader/bin/archive-loader=$SOURCE_ROOT/archive-loader/bin/archive-loader"
)
expect_failure "duplicate source mapping" "$WORK_DIR/duplicate-output" "${DUPLICATE_ARGS[@]}" --allow-synthetic

printf 'altered source bytes\n' > "$SOURCE_ROOT/archive-loader/red4ext/runtime.txt"
expect_failure "altered source bytes" "$WORK_DIR/altered-output" "${SOURCE_ARGS[@]}" --allow-synthetic
cp "$FIXTURE_ROOT/package/archive-loader/red4ext/runtime.txt" "$SOURCE_ROOT/archive-loader/red4ext/runtime.txt"

PROVENANCE_BACKUP="$WORK_DIR/provenance.backup.json"
cp "$PROVENANCE" "$PROVENANCE_BACKUP"
python3 - "$PROVENANCE" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
document = json.loads(path.read_text(encoding="utf-8"))
for item in document["inputs"]:
    if item["packagePath"] == "archive-loader/bin/archive-loader":
        item["mode"] = "0644"
        break
path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
expect_failure "wrong expected mode" "$WORK_DIR/wrong-mode-output" "${SOURCE_ARGS[@]}" --allow-synthetic
mv "$PROVENANCE_BACKUP" "$PROVENANCE"

UNKNOWN_ARGS=(
    "${SOURCE_ARGS[@]}"
    --source "archive-loader/missing-from-manifest.txt=$SOURCE_ROOT/archive-loader/red4ext/runtime.txt"
)
expect_failure "source mapping missing from manifest" "$WORK_DIR/unknown-output" "${UNKNOWN_ARGS[@]}" --allow-synthetic

RACE_BIN="$WORK_DIR/race-bin"
RACE_OUTPUT="$WORK_DIR/race output"
mkdir -p "$RACE_BIN"
cat > "$RACE_BIN/mkdir" <<EOF
#!/usr/bin/env bash
if [ "\$#" -eq 1 ] && [ "\$1" = "$RACE_OUTPUT" ]; then
    /bin/mkdir "\$1"
    printf 'external sentinel\\n' > "\$1/external-sentinel"
    exit 1
fi
exec /bin/mkdir "\$@"
EOF
chmod +x "$RACE_BIN/mkdir"
(
    PATH="$RACE_BIN:$PATH"
    export PATH
    expect_failure "external output-root creator" "$RACE_OUTPUT" "${SOURCE_ARGS[@]}" --allow-synthetic
)
assert_external_replacement_root "$RACE_OUTPUT"

make_replacement_hook() {
    local hook_path="$1"
    cat > "$hook_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
replacement_root="$1"
rm -rf "$replacement_root"
mkdir "$replacement_root"
printf 'external sentinel\n' > "$replacement_root/external-sentinel"
EOF
    chmod +x "$hook_path"
}

AFTER_CLAIM_HOOK="$WORK_DIR/after-claim-hook"
AFTER_CLAIM_OUTPUT="$WORK_DIR/after-claim output"
make_replacement_hook "$AFTER_CLAIM_HOOK"
(
    ARCHIVE_LOADER_PREPARE_TEST_AFTER_CLAIM_HOOK="$AFTER_CLAIM_HOOK"
    export ARCHIVE_LOADER_PREPARE_TEST_AFTER_CLAIM_HOOK
    expect_failure "replacement after output-root claim" "$AFTER_CLAIM_OUTPUT" "${SOURCE_ARGS[@]}" --allow-synthetic
)
assert_external_replacement_root "$AFTER_CLAIM_OUTPUT"

CLEANUP_PROVENANCE_BACKUP="$WORK_DIR/cleanup-provenance.backup.json"
cp "$PROVENANCE" "$CLEANUP_PROVENANCE_BACKUP"
python3 - "$PROVENANCE" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
document = json.loads(path.read_text(encoding="utf-8"))
for item in document["inputs"]:
    if item["packagePath"] == "archive-loader/bin/archive-loader":
        item["mode"] = "0644"
        break
path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
CLEANUP_HOOK="$WORK_DIR/cleanup-hook"
CLEANUP_OUTPUT="$WORK_DIR/cleanup-race output"
make_replacement_hook "$CLEANUP_HOOK"
(
    ARCHIVE_LOADER_PREPARE_TEST_BEFORE_CLEANUP_HOOK="$CLEANUP_HOOK"
    export ARCHIVE_LOADER_PREPARE_TEST_BEFORE_CLEANUP_HOOK
    expect_failure "replacement at cleanup boundary" "$CLEANUP_OUTPUT" "${SOURCE_ARGS[@]}" --allow-synthetic
)
mv "$CLEANUP_PROVENANCE_BACKUP" "$PROVENANCE"
assert_external_replacement_root "$CLEANUP_OUTPUT"

UNDECLARED_OUTPUT="$WORK_DIR/undeclared-output"
mkdir -p "$UNDECLARED_OUTPUT"
printf 'must remain untouched\n' > "$UNDECLARED_OUTPUT/undeclared.txt"
expect_failure "undeclared final-root file" "$UNDECLARED_OUTPUT" "${SOURCE_ARGS[@]}" --allow-synthetic
[ -f "$UNDECLARED_OUTPUT/undeclared.txt" ] || {
    echo "ERROR: failed staging removed an existing final-root file" >&2
    exit 1
}

expect_failure "synthetic provenance in production mode" "$WORK_DIR/production-output" "${SOURCE_ARGS[@]}" --production

OUTPUT_ROOT="$WORK_DIR/staged output"
expect_synthetic_success "$OUTPUT_ROOT" "${SOURCE_ARGS[@]}"

python3 - "$OUTPUT_ROOT" "$SOURCE_ROOT" "$MANIFEST" <<'PY'
import json
import pathlib
import stat
import sys

output_root = pathlib.Path(sys.argv[1])
source_root = pathlib.Path(sys.argv[2])
manifest = json.loads(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"))
expected_paths = sorted(entry["packagePath"] for entry in manifest["managedFiles"])
actual_paths = sorted(
    path.relative_to(output_root).as_posix()
    for path in output_root.rglob("*")
    if path.is_file()
)
if actual_paths != expected_paths:
    raise SystemExit(f"ERROR: staged file listing differs: {actual_paths!r}")
for entry in manifest["managedFiles"]:
    package_path = entry["packagePath"]
    staged = output_root / package_path
    source = source_root / package_path
    if staged.read_bytes() != source.read_bytes():
        raise SystemExit(f"ERROR: staged bytes differ: {package_path}")
    expected_mode = 0o755 if package_path in {
        "archive-loader/bin/archive-loader",
        "archive-loader/setup.command",
    } else 0o644
    actual_mode = stat.S_IMODE(staged.stat().st_mode)
    if actual_mode != expected_mode:
        raise SystemExit(f"ERROR: staged mode differs for {package_path}: {actual_mode:o}")
if (source_root / "unrelated-vendor-file.txt").read_text(encoding="utf-8") != "unrelated vendor file\n":
    raise SystemExit("ERROR: unrelated external source file was changed")
if (output_root / "unrelated-vendor-file.txt").exists():
    raise SystemExit("ERROR: unrelated external source file was copied")
PY

if [ -e "$REPOSITORY_DIR/release/evidence/provenance.json" ]; then
    echo "ERROR: staging test found fixture evidence in release/evidence" >&2
    exit 1
fi

echo "release prepare inputs test passed"
