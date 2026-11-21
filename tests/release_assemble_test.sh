#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSEMBLER="$REPOSITORY_DIR/release/assemble.sh"
FIXTURE_HELPER="$REPOSITORY_DIR/tests/fixtures/release-inputs/synthetic/create_fixture.sh"
WORK_DIR="$(mktemp -d /private/tmp/archive-loader-release-test.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() { echo "ERROR: $1" >&2; exit 1; }

FIXTURE_ROOT="$WORK_DIR/synthetic fixture"
VERSION="0.1.3"
"$FIXTURE_HELPER" "$FIXTURE_ROOT" "$VERSION"
PACKAGE_ROOT="$FIXTURE_ROOT/package"
MANIFEST="$PACKAGE_ROOT/archive-loader/compatibility/manifest.json"
EVIDENCE_DIR="$FIXTURE_ROOT/evidence"
BUILD_DIR="$FIXTURE_ROOT/build"
STUB_DIR="$FIXTURE_ROOT/stubs"
ZIP="$BUILD_DIR/archive-loader-$VERSION-macos-arm64.zip"

run_assembler() {
    ARCHIVE_LOADER_REPOSITORY_DIR="$FIXTURE_ROOT" \
    ARCHIVE_LOADER_PACKAGE_ROOT="$PACKAGE_ROOT" \
    ARCHIVE_LOADER_MANIFEST="$MANIFEST" \
    ARCHIVE_LOADER_RELEASE_EVIDENCE_DIR="$EVIDENCE_DIR" \
    ARCHIVE_LOADER_BUILD_DIR="$BUILD_DIR" \
    ARCHIVE_LOADER_ALLOW_SYNTHETIC=1 \
    PATH="$STUB_DIR:$PATH" \
        "$ASSEMBLER" --version "$VERSION"
}

if ARCHIVE_LOADER_REPOSITORY_DIR="$FIXTURE_ROOT" ARCHIVE_LOADER_PACKAGE_ROOT="$PACKAGE_ROOT" \
    ARCHIVE_LOADER_MANIFEST="$MANIFEST" ARCHIVE_LOADER_RELEASE_EVIDENCE_DIR="$EVIDENCE_DIR" \
    ARCHIVE_LOADER_BUILD_DIR="$BUILD_DIR" PATH="$STUB_DIR:$PATH" \
    "$ASSEMBLER" --version "$VERSION" >/dev/null 2>&1; then
    fail "assembler accepted synthetic evidence without explicit opt-in"
fi

produced="$(run_assembler)" || fail "assemble.sh failed"
[ "$produced" = "$ZIP" ] || fail "assembler printed $produced, expected $ZIP"
[ -f "$ZIP" ] || fail "assembler did not create zip"
unzip -p "$ZIP" archive-loader/compatibility/manifest.json > "$WORK_DIR/zipped-manifest.json"
cmp -s "$MANIFEST" "$WORK_DIR/zipped-manifest.json" || fail "assembled manifest bytes differ"
expected_listing="$(jq -r '.managedFiles[].packagePath' "$MANIFEST" | sort)"
actual_listing="$(unzip -Z1 "$ZIP" | grep -v '/$' | sort)"
[ "$actual_listing" = "$expected_listing" ] || fail "zip listing differs from packagePath entries"

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

OUTPUT_EVIDENCE="$EVIDENCE_DIR/release-output.json"
[ -f "$OUTPUT_EVIDENCE" ] || fail "missing release output evidence"
[ "$(jq -r '.zipSha256' "$OUTPUT_EVIDENCE")" = "$(shasum -a 256 "$ZIP" | awk '{print $1}')" ] || fail "wrong zip hash evidence"
[ "$(jq -r '.zipListing[]' "$OUTPUT_EVIDENCE" | sort)" = "$actual_listing" ] || fail "wrong zip listing evidence"

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
