#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSEMBLER="$REPOSITORY_DIR/release/assemble.sh"
FIXTURE_HELPER="$REPOSITORY_DIR/tests/fixtures/release-inputs/synthetic/create_fixture.sh"
PREFLIGHT_FIXTURE="$REPOSITORY_DIR/tests/fixtures/release-inputs/synthetic/preflight.json"
WORK_DIR="$(mktemp -d /private/tmp/archive-loader-readiness-test.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() { echo "ERROR: $1" >&2; exit 1; }

VERSION="0.1.3"

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
document["commands"][0]["stdoutPath"] = str(stdout_path.resolve())
document["commands"][0]["stderrPath"] = str(stderr_path.resolve())
output_path.write_text(
    json.dumps(document, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY
}

create_case() {
    local case_name="$1"
    local fixture_root="$WORK_DIR/$case_name"
    "$FIXTURE_HELPER" "$fixture_root" "$VERSION"
    materialize_preflight "$fixture_root" "$fixture_root/evidence/preflight.json"
    printf '%s\n' "$fixture_root"
}

run_assembler() {
    local fixture_root="$1"
    shift
    local package_root="$fixture_root/package"
    local evidence_dir="$fixture_root/evidence"
    local build_dir="$fixture_root/build"
    local stub_dir="$fixture_root/stubs"
    ARCHIVE_LOADER_REPOSITORY_DIR="$fixture_root" \
    ARCHIVE_LOADER_PACKAGE_ROOT="$package_root" \
    ARCHIVE_LOADER_MANIFEST="$package_root/archive-loader/compatibility/manifest.json" \
    ARCHIVE_LOADER_RELEASE_EVIDENCE_DIR="$evidence_dir" \
    ARCHIVE_LOADER_BUILD_DIR="$build_dir" \
    ARCHIVE_LOADER_ALLOW_SYNTHETIC=1 \
    PATH="$stub_dir:$PATH" \
        "$ASSEMBLER" --version "$VERSION" "$@"
}

assert_not_ready() {
    local case_name="$1"
    local fixture_root="$2"
    local report="$fixture_root/evidence/readiness.json"
    if run_assembler "$fixture_root" > "$fixture_root/assembler.stdout" 2> "$fixture_root/assembler.stderr"; then
        fail "$case_name unexpectedly assembled"
    fi
    [ -f "$report" ] || fail "$case_name did not write readiness report"
    jq -e '.status == "blocked" or .status == "unresolved"' "$report" >/dev/null \
        || fail "$case_name produced an invalid readiness status"
    jq -e '.status != "ready" and (.reasons | length > 0) and (.evidencePaths | length > 0) and (.commands | length > 0) and (.finalZip == null)' "$report" >/dev/null \
        || fail "$case_name produced ready or incomplete readiness evidence"
}

fixture_root="$(create_case missing-production-payload)"
rm -f "$fixture_root/package/archive-loader/bin/archive-loader"
assert_not_ready "missing production payload" "$fixture_root"

fixture_root="$(create_case missing-provenance)"
rm -f "$fixture_root/evidence/provenance.json"
assert_not_ready "missing provenance" "$fixture_root"

fixture_root="$(create_case target-mismatch)"
jq '.targetIdentity.version = "9.9.9"' \
    "$fixture_root/evidence/target-evidence.json" > "$fixture_root/evidence/target-evidence.tmp"
mv "$fixture_root/evidence/target-evidence.tmp" "$fixture_root/evidence/target-evidence.json"
assert_not_ready "target mismatch" "$fixture_root"

fixture_root="$(create_case missing-signing-evidence)"
jq 'del(.inputs[0].nativeEvidence)' \
    "$fixture_root/evidence/provenance.json" > "$fixture_root/evidence/provenance.tmp"
mv "$fixture_root/evidence/provenance.tmp" "$fixture_root/evidence/provenance.json"
assert_not_ready "missing signing evidence" "$fixture_root"

fixture_root="$(create_case missing-archive-hash)"
jq '.inputs[0].archiveSha256 = null' \
    "$fixture_root/evidence/provenance.json" > "$fixture_root/evidence/provenance.tmp"
mv "$fixture_root/evidence/provenance.tmp" "$fixture_root/evidence/provenance.json"
assert_not_ready "missing archive hash" "$fixture_root"

fixture_root="$(create_case blocked-linker)"
printf 'arm64e.x1\n' > "$fixture_root/preflight-success.stderr"
jq '.commands[0].result = "blocked_toolchain_linker"' \
    "$fixture_root/evidence/preflight.json" > "$fixture_root/evidence/preflight.tmp"
mv "$fixture_root/evidence/preflight.tmp" "$fixture_root/evidence/preflight.json"
assert_not_ready "blocked linker" "$fixture_root"
jq -e '.status == "blocked" and (.reasons | join(" ") | contains("arm64e.x1"))' \
    "$fixture_root/evidence/readiness.json" >/dev/null \
    || fail "blocked linker evidence was not retained"

fixture_root="$(create_case ordinary-preflight-failure)"
printf 'ordinary command failure\n' > "$fixture_root/preflight-success.stderr"
jq '.commands[0].exitStatus = 7 | .commands[0].result = "failed"' \
    "$fixture_root/evidence/preflight.json" > "$fixture_root/evidence/preflight.tmp"
mv "$fixture_root/evidence/preflight.tmp" "$fixture_root/evidence/preflight.json"
assert_not_ready "ordinary preflight failure" "$fixture_root"
jq -e '.status != "ready" and ([.checks[] | select(.id == "native-preflight")][0].status == "failed")' \
    "$fixture_root/evidence/readiness.json" >/dev/null \
    || fail "ordinary preflight failure was not retained as failed readiness evidence"

fixture_root="$(create_case complete-synthetic-assembly)"
produced_zip="$(run_assembler "$fixture_root")" || fail "complete synthetic assembly failed"
expected_zip="$fixture_root/build/archive-loader-$VERSION-macos-arm64.zip"
[ "$produced_zip" = "$expected_zip" ] || fail "complete synthetic assembly returned $produced_zip"
jq -e --arg zip "$expected_zip" \
    '.status == "blocked" and .productionCompatible == false and (.reasons | length > 0) and .finalZip.path == $zip and (.finalZip.sha256 | test("^[0-9a-f]{64}$")) and (.finalZip.listing | length > 0) and ([.commands[] | select(.id == "assembly")] | length == 1) and ([.commands[] | select(.id == "pre-assembly-identity")] | length == 1)' \
    "$fixture_root/evidence/readiness.json" >/dev/null \
    || fail "post-assembly readiness evidence was incomplete or production-ready"
jq -e '(.identity | has("readinessSha256")) | not' "$fixture_root/evidence/release-output.json" >/dev/null \
    || fail "pre-assembly identity included post-assembly readiness"
jq -e '
    ([.packageFiles[] | select(.packagePath == "archive-loader/compatibility/manifest.json")][0]
        | .status == "passed"
        and .hashComparison == "masked-manifest-self-hash"
        and .actualSha256 != .expectedSha256
        and .maskedSha256 == .declaredSha256
        and .maskedSha256 == .expectedSha256)
' "$fixture_root/evidence/readiness.json" >/dev/null \
    || fail "manifest self-entry did not report ordinary, masked, and declared hashes separately"

fixture_root="$(create_case package-hash-mode-mismatch)"
printf 'tampered synthetic runtime\n' > "$fixture_root/package/archive-loader/red4ext/runtime.txt"
chmod 0644 "$fixture_root/package/archive-loader/bin/archive-loader"
assert_not_ready "package hash and mode mismatch" "$fixture_root"
jq -e '([.packageFiles[] | select(.packagePath == "archive-loader/red4ext/runtime.txt")][0] | .status == "failed" and .actualSha256 != .expectedSha256) and ([.packageFiles[] | select(.packagePath == "archive-loader/bin/archive-loader")][0] | .status == "failed" and .actualMode == "0644" and .expectedMode == "0755")' \
    "$fixture_root/evidence/readiness.json" >/dev/null \
    || fail "package hash or mode mismatch was not retained in readiness evidence"

fixture_root="$(create_case quarantine-report)"
run_assembler "$fixture_root" >/dev/null || fail "could not create quarantine fixture pair"
quarantine_zip="$fixture_root/build/archive-loader-$VERSION-macos-arm64.zip"
printf 'stale synthetic bytes\n' >> "$quarantine_zip"
stale_hash="$(shasum -a 256 "$quarantine_zip" | awk '{print $1}')"
run_assembler "$fixture_root" --replace-existing >/dev/null || fail "could not replace quarantine fixture pair"
jq -e --arg original "$quarantine_zip" --arg hash "$stale_hash" \
    '.quarantine.status == "passed" and (.quarantine.artifacts | length == 2) and ([.quarantine.artifacts[] | select(.originalPath == $original and .moveResult == "moved" and .sha256 == $hash and (.quarantinePath | length > 0))] | length == 1)' \
    "$fixture_root/evidence/readiness.json" >/dev/null \
    || fail "quarantine report did not retain original path, destination, hash, and move result"

echo "release readiness test passed"
