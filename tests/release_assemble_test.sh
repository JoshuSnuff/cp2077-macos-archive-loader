#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSEMBLER="$REPOSITORY_DIR/release/assemble.sh"
FIXTURE_HELPER="$REPOSITORY_DIR/tests/fixtures/release-inputs/synthetic/create_fixture.sh"
PREFLIGHT_FIXTURE="$REPOSITORY_DIR/tests/fixtures/release-inputs/synthetic/preflight.json"
WORK_DIR="$(mktemp -d /private/tmp/archive-loader-release-test.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() { echo "ERROR: $1" >&2; exit 1; }

VERSION="0.1.3"
FIXTURE_ROOT="$WORK_DIR/synthetic fixture"
"$FIXTURE_HELPER" "$FIXTURE_ROOT" "$VERSION"
PACKAGE_ROOT="$FIXTURE_ROOT/package"
MANIFEST="$PACKAGE_ROOT/archive-loader/compatibility/manifest.json"
EVIDENCE_DIR="$FIXTURE_ROOT/evidence"
BUILD_DIR="$FIXTURE_ROOT/build"
STUB_DIR="$FIXTURE_ROOT/stubs"
ZIP="$BUILD_DIR/archive-loader-$VERSION-macos-arm64.zip"
OUTPUT_EVIDENCE="$EVIDENCE_DIR/release-output.json"
PREFLIGHT="$EVIDENCE_DIR/preflight.json"

materialize_preflight() {
    local fixture_root="$1"
    local output="$2"
    local stdout_path="$fixture_root/preflight-success.stdout"
    local stderr_path="$fixture_root/preflight-success.stderr"
    : > "$stdout_path"
    : > "$stderr_path"
    python3 - "$PREFLIGHT_FIXTURE" "$output" "$stdout_path" "$stderr_path" <<'PY'
import json
import pathlib
import sys

template_path, output_path, stdout_path, stderr_path = map(pathlib.Path, sys.argv[1:])
document = json.loads(template_path.read_text(encoding="utf-8"))
if document.get("synthetic") is not True:
    raise SystemExit("synthetic preflight fixture is not explicitly marked")
document["commands"][0]["stdoutPath"] = str(stdout_path.resolve())
document["commands"][0]["stderrPath"] = str(stderr_path.resolve())
output_path.write_text(
    json.dumps(document, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY
}

materialize_preflight "$FIXTURE_ROOT" "$PREFLIGHT"

run_assembler() {
    ARCHIVE_LOADER_REPOSITORY_DIR="$FIXTURE_ROOT" \
    ARCHIVE_LOADER_PACKAGE_ROOT="$PACKAGE_ROOT" \
    ARCHIVE_LOADER_MANIFEST="$MANIFEST" \
    ARCHIVE_LOADER_RELEASE_EVIDENCE_DIR="$EVIDENCE_DIR" \
    ARCHIVE_LOADER_BUILD_DIR="$BUILD_DIR" \
    ARCHIVE_LOADER_ALLOW_SYNTHETIC=1 \
    PATH="$STUB_DIR:$PATH" \
        "$ASSEMBLER" --version "$VERSION" "$@"
}

reset_current_pair() {
    rm -f "$ZIP" "$OUTPUT_EVIDENCE"
    run_assembler >/dev/null || fail "could not create current release pair"
}

quarantine_count() {
    if [ ! -d "$BUILD_DIR/quarantine" ]; then
        printf '0\n'
        return
    fi
    find "$BUILD_DIR/quarantine" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' '
}

latest_quarantine() {
    find "$BUILD_DIR/quarantine" -mindepth 1 -maxdepth 1 -type d -print | sort | tail -n 1
}

if ARCHIVE_LOADER_REPOSITORY_DIR="$FIXTURE_ROOT" ARCHIVE_LOADER_PACKAGE_ROOT="$PACKAGE_ROOT" \
    ARCHIVE_LOADER_MANIFEST="$MANIFEST" ARCHIVE_LOADER_RELEASE_EVIDENCE_DIR="$EVIDENCE_DIR" \
    ARCHIVE_LOADER_BUILD_DIR="$BUILD_DIR" PATH="$STUB_DIR:$PATH" \
    "$ASSEMBLER" --version "$VERSION" >/dev/null 2>&1; then
    fail "assembler accepted synthetic evidence without explicit opt-in"
fi

produced="$(umask 077; run_assembler)" || fail "assemble.sh failed"
[ "$produced" = "$ZIP" ] || fail "assembler printed $produced, expected $ZIP"
[ -f "$ZIP" ] || fail "assembler did not create zip"
unzip -p "$ZIP" archive-loader/compatibility/manifest.json > "$WORK_DIR/zipped-manifest.json"
cmp -s "$MANIFEST" "$WORK_DIR/zipped-manifest.json" || fail "assembled manifest bytes differ"
expected_listing="$(jq -r '.managedFiles[].packagePath' "$MANIFEST" | sort)"
actual_listing="$(unzip -Z1 "$ZIP" | grep -v '/$')"
[ "$(printf '%s\n' "$actual_listing" | sort)" = "$expected_listing" ] || fail "zip listing differs from packagePath entries"

rm -rf "$WORK_DIR/mode-check"
mkdir -p "$WORK_DIR/mode-check"
unzip -q "$ZIP" -d "$WORK_DIR/mode-check"
while IFS= read -r package_path; do
    expected_mode=644
    case "$package_path" in
        archive-loader/bin/archive-loader|archive-loader/setup.command) expected_mode=755 ;;
    esac
    actual_mode="$(stat -f '%Lp' "$WORK_DIR/mode-check/$package_path")"
    [ "$actual_mode" = "$expected_mode" ] || fail "zip mode for $package_path is $actual_mode, expected $expected_mode"
done < <(jq -r '.managedFiles[].packagePath' "$MANIFEST")

while IFS=$'\t' read -r package_path game_path expected_hash; do
    extracted="$WORK_DIR/extracted/$package_path"
    mkdir -p "$(dirname "$extracted")"
    unzip -p "$ZIP" "$package_path" > "$extracted"
    if [ "$package_path" = "archive-loader/compatibility/manifest.json" ] && [ "$game_path" = "$package_path" ]; then
        actual_hash="$(python3 - "$extracted" <<'PY'
import hashlib, json, pathlib, sys
b = pathlib.Path(sys.argv[1]).read_bytes()
d = json.loads(b)
entry = next(x for x in d["managedFiles"] if x["packagePath"] == x["gamePath"] == "archive-loader/compatibility/manifest.json")
needle = ('"sha256": "' + entry["sha256"] + '"').encode()
assert b.count(needle) == 1
start = b.index(needle) + len(b'"sha256": "')
print(hashlib.sha256(b[:start] + b'0' * 64 + b[start + 64:]).hexdigest())
PY
)"
    else
        actual_hash="$(shasum -a 256 "$extracted" | awk '{print $1}')"
    fi
    [ "$actual_hash" = "$expected_hash" ] || fail "hash mismatch for $package_path"
done < <(jq -r '.managedFiles[] | [.packagePath, .gamePath, .sha256] | @tsv' "$MANIFEST")

[ -f "$OUTPUT_EVIDENCE" ] || fail "missing release output evidence"
python3 - "$MANIFEST" "$EVIDENCE_DIR/provenance.json" "$PREFLIGHT" "$OUTPUT_EVIDENCE" "$ZIP" <<'PY'
import hashlib
import json
import pathlib
import subprocess
import sys

manifest_path, provenance_path, preflight_path, output_path, zip_path = map(pathlib.Path, sys.argv[1:])
manifest_bytes = manifest_path.read_bytes()
manifest = json.loads(manifest_bytes)
provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
preflight = json.loads(preflight_path.read_text(encoding="utf-8"))
output = json.loads(output_path.read_text(encoding="utf-8"))

def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()

def digest(value):
    return hashlib.sha256(value).hexdigest()

self_entry = next(
    entry for entry in manifest["managedFiles"]
    if entry["packagePath"] == entry["gamePath"] == "archive-loader/compatibility/manifest.json"
)
needle = ('"sha256": "' + self_entry["sha256"] + '"').encode()
if manifest_bytes.count(needle) != 1:
    raise SystemExit("ERROR: cannot independently locate manifest self hash")
start = manifest_bytes.index(needle) + len(b'"sha256": "')
masked_hash = digest(manifest_bytes[:start] + b"0" * 64 + manifest_bytes[start + 64:])
tuples = sorted(
    [item["packagePath"], item["manifestSha256"], item["mode"]]
    for item in provenance["inputs"]
)
expected_identity = {
    "loaderVersion": manifest["loaderVersion"],
    "manifestSchema": manifest["schema"],
    "manifestSelfSha256": masked_hash,
    "manifestSha256": digest(manifest_bytes),
    "packageTupleSha256": digest(canonical(tuples)),
    "preflightSha256": digest(canonical(preflight)),
    "provenanceSha256": digest(canonical(provenance)),
}
if output.get("schema") != "archive-loader-release-output/v1":
    raise SystemExit("ERROR: wrong release output schema")
if output.get("identity") != expected_identity:
    raise SystemExit("ERROR: release output identity is missing or noncanonical")
if output.get("zipSha256") != digest(zip_path.read_bytes()):
    raise SystemExit("ERROR: wrong zip hash evidence")
listing = subprocess.check_output(["unzip", "-Z1", str(zip_path)], text=True).splitlines()
listing = [entry for entry in listing if not entry.endswith("/")]
if output.get("zipListing") != listing:
    raise SystemExit("ERROR: release output does not preserve exact zip listing")
PY

zip_hash="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
evidence_hash="$(shasum -a 256 "$OUTPUT_EVIDENCE" | awk '{print $1}')"
[ "$(run_assembler)" = "$ZIP" ] || fail "current release pair was not reused"
[ "$(shasum -a 256 "$ZIP" | awk '{print $1}')" = "$zip_hash" ] || fail "current zip was rewritten"
[ "$(shasum -a 256 "$OUTPUT_EVIDENCE" | awk '{print $1}')" = "$evidence_hash" ] || fail "current output evidence was rewritten"

printf 'stale zip bytes\n' >> "$ZIP"
stale_zip_hash="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
if run_assembler >/dev/null 2>&1; then fail "default assembly replaced a stale zip"; fi
[ "$(shasum -a 256 "$ZIP" | awk '{print $1}')" = "$stale_zip_hash" ] || fail "default refusal changed stale zip"
before_count="$(quarantine_count)"
run_assembler --replace-existing >/dev/null || fail "explicit replacement did not quarantine stale zip"
[ "$(quarantine_count)" -eq $((before_count + 1)) ] || fail "stale zip replacement created no quarantine directory"
quarantine_dir="$(latest_quarantine)"
[ "$(shasum -a 256 "$quarantine_dir/$(basename "$ZIP")" | awk '{print $1}')" = "$stale_zip_hash" ] || fail "quarantine did not preserve stale zip"
[ -f "$quarantine_dir/release-output.json" ] || fail "stale zip replacement did not quarantine paired evidence"

reset_current_pair
jq '.identity.loaderVersion = "STALE-SYNTHETIC"' "$OUTPUT_EVIDENCE" > "$WORK_DIR/stale-output.json"
mv "$WORK_DIR/stale-output.json" "$OUTPUT_EVIDENCE"
before_count="$(quarantine_count)"
run_assembler --replace-existing >/dev/null || fail "explicit replacement did not quarantine stale evidence"
[ "$(quarantine_count)" -eq $((before_count + 1)) ] || fail "stale evidence replacement created no quarantine directory"
[ "$(jq -r '.identity.loaderVersion' "$(latest_quarantine)/release-output.json")" = "STALE-SYNTHETIC" ] || fail "quarantine did not preserve stale evidence"

reset_current_pair
rm -f "$OUTPUT_EVIDENCE"
before_count="$(quarantine_count)"
run_assembler --replace-existing >/dev/null || fail "explicit replacement rejected zip-only stale output"
[ "$(quarantine_count)" -eq $((before_count + 1)) ] || fail "zip-only output was not quarantined"

reset_current_pair
rm -f "$ZIP"
before_count="$(quarantine_count)"
run_assembler --replace-existing >/dev/null || fail "explicit replacement rejected evidence-only stale output"
[ "$(quarantine_count)" -eq $((before_count + 1)) ] || fail "evidence-only output was not quarantined"

reset_current_pair
jq '.identity = "MALFORMED-SYNTHETIC"' "$OUTPUT_EVIDENCE" > "$WORK_DIR/malformed-output.json"
mv "$WORK_DIR/malformed-output.json" "$OUTPUT_EVIDENCE"
before_count="$(quarantine_count)"
run_assembler --replace-existing >/dev/null || fail "explicit replacement rejected malformed identity"
[ "$(quarantine_count)" -eq $((before_count + 1)) ] || fail "malformed identity was not quarantined"

FAILED_ROOT="$WORK_DIR/failed quarantine fixture"
"$FIXTURE_HELPER" "$FAILED_ROOT" "$VERSION"
materialize_preflight "$FAILED_ROOT" "$FAILED_ROOT/evidence/preflight.json"
mkdir -p "$FAILED_ROOT/build"
printf 'original stale zip\n' > "$FAILED_ROOT/build/archive-loader-$VERSION-macos-arm64.zip"
printf 'quarantine path blocker\n' > "$FAILED_ROOT/build/quarantine"
failed_hash="$(shasum -a 256 "$FAILED_ROOT/build/archive-loader-$VERSION-macos-arm64.zip" | awk '{print $1}')"
if ARCHIVE_LOADER_REPOSITORY_DIR="$FAILED_ROOT" \
    ARCHIVE_LOADER_PACKAGE_ROOT="$FAILED_ROOT/package" \
    ARCHIVE_LOADER_MANIFEST="$FAILED_ROOT/package/archive-loader/compatibility/manifest.json" \
    ARCHIVE_LOADER_RELEASE_EVIDENCE_DIR="$FAILED_ROOT/evidence" \
    ARCHIVE_LOADER_BUILD_DIR="$FAILED_ROOT/build" \
    ARCHIVE_LOADER_ALLOW_SYNTHETIC=1 PATH="$FAILED_ROOT/stubs:$PATH" \
    "$ASSEMBLER" --version "$VERSION" --replace-existing >/dev/null 2>&1; then
    fail "assembler succeeded when quarantine could not be created"
fi
[ "$(shasum -a 256 "$FAILED_ROOT/build/archive-loader-$VERSION-macos-arm64.zip" | awk '{print $1}')" = "$failed_hash" ] || fail "failed quarantine changed original artifact"

MOVE_FAILURE_ROOT="$WORK_DIR/second move failure fixture"
"$FIXTURE_HELPER" "$MOVE_FAILURE_ROOT" "$VERSION"
materialize_preflight "$MOVE_FAILURE_ROOT" "$MOVE_FAILURE_ROOT/evidence/preflight.json"
ARCHIVE_LOADER_REPOSITORY_DIR="$MOVE_FAILURE_ROOT" \
    ARCHIVE_LOADER_PACKAGE_ROOT="$MOVE_FAILURE_ROOT/package" \
    ARCHIVE_LOADER_MANIFEST="$MOVE_FAILURE_ROOT/package/archive-loader/compatibility/manifest.json" \
    ARCHIVE_LOADER_RELEASE_EVIDENCE_DIR="$MOVE_FAILURE_ROOT/evidence" \
    ARCHIVE_LOADER_BUILD_DIR="$MOVE_FAILURE_ROOT/build" \
    ARCHIVE_LOADER_ALLOW_SYNTHETIC=1 PATH="$MOVE_FAILURE_ROOT/stubs:$PATH" \
    "$ASSEMBLER" --version "$VERSION" >/dev/null || fail "could not create second-move fixture pair"
move_failure_zip="$MOVE_FAILURE_ROOT/build/archive-loader-$VERSION-macos-arm64.zip"
move_failure_evidence="$MOVE_FAILURE_ROOT/evidence/release-output.json"
printf 'stale pair bytes\n' >> "$move_failure_zip"
move_failure_zip_hash="$(shasum -a 256 "$move_failure_zip" | awk '{print $1}')"
move_failure_evidence_hash="$(shasum -a 256 "$move_failure_evidence" | awk '{print $1}')"
cat > "$MOVE_FAILURE_ROOT/stubs/mv" <<'SH'
#!/bin/sh
if [ "$1" = "$ARCHIVE_LOADER_TEST_FAIL_MOVE_SOURCE" ]; then
    exit 73
fi
exec /bin/mv "$@"
SH
chmod 0755 "$MOVE_FAILURE_ROOT/stubs/mv"
if ARCHIVE_LOADER_TEST_FAIL_MOVE_SOURCE="$move_failure_evidence" \
    ARCHIVE_LOADER_REPOSITORY_DIR="$MOVE_FAILURE_ROOT" \
    ARCHIVE_LOADER_PACKAGE_ROOT="$MOVE_FAILURE_ROOT/package" \
    ARCHIVE_LOADER_MANIFEST="$MOVE_FAILURE_ROOT/package/archive-loader/compatibility/manifest.json" \
    ARCHIVE_LOADER_RELEASE_EVIDENCE_DIR="$MOVE_FAILURE_ROOT/evidence" \
    ARCHIVE_LOADER_BUILD_DIR="$MOVE_FAILURE_ROOT/build" \
    ARCHIVE_LOADER_ALLOW_SYNTHETIC=1 PATH="$MOVE_FAILURE_ROOT/stubs:$PATH" \
    "$ASSEMBLER" --version "$VERSION" --replace-existing >/dev/null 2>&1; then
    fail "assembler succeeded when the second quarantine move failed"
fi
[ "$(shasum -a 256 "$move_failure_zip" | awk '{print $1}')" = "$move_failure_zip_hash" ] || fail "second-move rollback did not preserve original zip"
[ "$(shasum -a 256 "$move_failure_evidence" | awk '{print $1}')" = "$move_failure_evidence_hash" ] || fail "second-move failure changed original evidence"

MUTATION_ROOT="$WORK_DIR/source mutation fixture"
"$FIXTURE_HELPER" "$MUTATION_ROOT" "$VERSION"
materialize_preflight "$MUTATION_ROOT" "$MUTATION_ROOT/evidence/preflight.json"
mutation_source="$MUTATION_ROOT/package/archive-loader/red4ext/runtime.txt"
cat > "$MUTATION_ROOT/stubs/cp" <<'SH'
#!/bin/sh
if [ "$1" = "$ARCHIVE_LOADER_TEST_MUTATE_SOURCE" ]; then
    printf 'mutated after source validation\n' > "$1"
fi
exec /bin/cp "$@"
SH
chmod 0755 "$MUTATION_ROOT/stubs/cp"
if ARCHIVE_LOADER_TEST_MUTATE_SOURCE="$mutation_source" \
    ARCHIVE_LOADER_REPOSITORY_DIR="$MUTATION_ROOT" \
    ARCHIVE_LOADER_PACKAGE_ROOT="$MUTATION_ROOT/package" \
    ARCHIVE_LOADER_MANIFEST="$MUTATION_ROOT/package/archive-loader/compatibility/manifest.json" \
    ARCHIVE_LOADER_RELEASE_EVIDENCE_DIR="$MUTATION_ROOT/evidence" \
    ARCHIVE_LOADER_BUILD_DIR="$MUTATION_ROOT/build" \
    ARCHIVE_LOADER_ALLOW_SYNTHETIC=1 PATH="$MUTATION_ROOT/stubs:$PATH" \
    "$ASSEMBLER" --version "$VERSION" >/dev/null 2>&1; then
    fail "assembler accepted source mutation between validation and copy"
fi
[ ! -e "$MUTATION_ROOT/build/archive-loader-$VERSION-macos-arm64.zip" ] || fail "source mutation published a zip"

RACE_ROOT="$WORK_DIR/publication race fixture"
"$FIXTURE_HELPER" "$RACE_ROOT" "$VERSION"
materialize_preflight "$RACE_ROOT" "$RACE_ROOT/evidence/preflight.json"
race_zip="$RACE_ROOT/build/archive-loader-$VERSION-macos-arm64.zip"
mkdir -p "$RACE_ROOT/build"
cat > "$RACE_ROOT/stubs/zip" <<'SH'
#!/bin/sh
/usr/bin/zip "$@" || exit $?
printf 'artifact created after precheck\n' > "$ARCHIVE_LOADER_TEST_RACE_TARGET"
SH
chmod 0755 "$RACE_ROOT/stubs/zip"
if ARCHIVE_LOADER_TEST_RACE_TARGET="$race_zip" \
    ARCHIVE_LOADER_REPOSITORY_DIR="$RACE_ROOT" \
    ARCHIVE_LOADER_PACKAGE_ROOT="$RACE_ROOT/package" \
    ARCHIVE_LOADER_MANIFEST="$RACE_ROOT/package/archive-loader/compatibility/manifest.json" \
    ARCHIVE_LOADER_RELEASE_EVIDENCE_DIR="$RACE_ROOT/evidence" \
    ARCHIVE_LOADER_BUILD_DIR="$RACE_ROOT/build" \
    ARCHIVE_LOADER_ALLOW_SYNTHETIC=1 PATH="$RACE_ROOT/stubs:$PATH" \
    "$ASSEMBLER" --version "$VERSION" >/dev/null 2>&1; then
    fail "assembler overwrote or accepted an artifact created after precheck"
fi
[ "$(cat "$race_zip")" = "artifact created after precheck" ] || fail "publication race overwrote the competing artifact"
[ ! -e "$RACE_ROOT/evidence/release-output.json" ] || fail "publication race wrote release output evidence"

reset_current_pair
rm -f "$ZIP" "$OUTPUT_EVIDENCE"
printf 'tampered\n' > "$PACKAGE_ROOT/archive-loader/red4ext/runtime.txt"
if run_assembler >/dev/null 2>&1; then fail "assembler accepted package hash drift"; fi
[ ! -e "$ZIP" ] || fail "hash failure left release artifact"
printf 'synthetic repository runtime\n' > "$PACKAGE_ROOT/archive-loader/red4ext/runtime.txt"

jq 'del(.inputs[0].source)' "$EVIDENCE_DIR/provenance.json" > "$WORK_DIR/incomplete.json"
mv "$WORK_DIR/incomplete.json" "$EVIDENCE_DIR/provenance.json"
if run_assembler >/dev/null 2>&1; then fail "assembler accepted incomplete provenance"; fi
[ ! -e "$ZIP" ] || fail "provenance failure left release artifact"

echo "release assemble test passed"
