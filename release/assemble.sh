#!/usr/bin/env bash
# Assembles the current read-only preflight release. It writes only beneath the
# repository build directory and never touches a game installation.
set -euo pipefail

SCRIPT_REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOSITORY_DIR="${ARCHIVE_LOADER_REPOSITORY_DIR:-$SCRIPT_REPOSITORY_DIR}"
VERSION=""

usage() {
    cat <<EOF
Usage: $(basename "$0") --version VERSION

Assemble build/archive-loader-VERSION-macos-arm64.zip with the archive-loader
runtime payload.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            if [ "$#" -lt 2 ]; then
                echo "ERROR: --version requires a value" >&2
                exit 2
            fi
            VERSION="$2"
            shift 2
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
done

if [ -z "$VERSION" ]; then
    echo "ERROR: --version is required" >&2
    usage >&2
    exit 2
fi
case "$VERSION" in
    *[!A-Za-z0-9._-]*)
        echo "ERROR: version may contain only letters, digits, dots, underscores, and hyphens" >&2
        exit 2
        ;;
esac

PACKAGE_ROOT="${ARCHIVE_LOADER_PACKAGE_ROOT:-$REPOSITORY_DIR}"
BUILD_DIR="${ARCHIVE_LOADER_BUILD_DIR:-$REPOSITORY_DIR/build}"
OUTPUT_ZIP="$BUILD_DIR/archive-loader-$VERSION-macos-arm64.zip"
MANIFEST="${ARCHIVE_LOADER_MANIFEST:-$PACKAGE_ROOT/compatibility/manifest.json}"
MANIFEST_CONTRACT="$SCRIPT_REPOSITORY_DIR/release/manifest_contract.sh"
EVIDENCE_DIR="${ARCHIVE_LOADER_RELEASE_EVIDENCE_DIR:-$REPOSITORY_DIR/release/evidence}"

if [ -e "$OUTPUT_ZIP" ]; then
    echo "ERROR: output already exists: $OUTPUT_ZIP" >&2
    exit 1
fi
if [ ! -x "$MANIFEST_CONTRACT" ] || [ ! -f "$MANIFEST" ]; then
    echo "ERROR: compatibility manifest and validator are required before assembly" >&2
    exit 1
fi
"$MANIFEST_CONTRACT" validate "$MANIFEST"

if [ ! -f "$EVIDENCE_DIR/provenance.json" ]; then
    echo "ERROR: immutable release provenance is required: $EVIDENCE_DIR/provenance.json" >&2
    exit 1
fi
python3 - "$EVIDENCE_DIR/provenance.json" "${ARCHIVE_LOADER_ALLOW_SYNTHETIC:-0}" <<'PY'
import json, pathlib, sys
doc = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if doc.get("schema") != "archive-loader-release-provenance/v1":
    raise SystemExit("ERROR: unsupported release provenance schema")
if doc.get("synthetic") and sys.argv[2] != "1":
    raise SystemExit("ERROR: synthetic provenance requires ARCHIVE_LOADER_ALLOW_SYNTHETIC=1")
inputs = doc.get("inputs")
if not isinstance(inputs, list) or not inputs:
    raise SystemExit("ERROR: provenance inputs are missing")
for index, item in enumerate(inputs):
    source = item.get("source") if isinstance(item, dict) else None
    if not isinstance(source, dict) or source.get("immutable") is not True or not source.get("url"):
        raise SystemExit(f"ERROR: provenance input {index} is not immutable")
    if not item.get("extractedSha256") or not item.get("manifestSha256"):
        raise SystemExit(f"ERROR: provenance input {index} is missing hashes")
PY

BINARY="$PACKAGE_ROOT/archive-loader/bin/archive-loader"
if [ ! -x "$BINARY" ]; then
    echo "ERROR: missing executable in package root: $BINARY" >&2
    exit 1
fi

# --version is hand-typed here but compiled into the binary, and once the
# directory leaves this machine nothing else records which build it holds. A
# mislabelled release is indistinguishable from a correct one, so refuse rather
# than name the payload after a version it does not report.
BINARY_VERSION="$("$BINARY" --version)"
if [ "$BINARY_VERSION" != "archive-loader $VERSION" ]; then
    echo "ERROR: --version $VERSION disagrees with the binary, which reports: $BINARY_VERSION" >&2
    echo "  rebuild bin/archive-loader, or pass the version it was built with" >&2
    exit 1
fi

# The __RESTRICT segment is what stops an ambient DYLD_INSERT_LIBRARIES from
# injecting RED4ext into the wrapper. Shipping without it is silent.
if ! otool -l "$BINARY" | grep -q "__RESTRICT"; then
    echo "ERROR: $BINARY has no __RESTRICT segment; do not ship it" >&2
    exit 1
fi

mkdir -p "$BUILD_DIR"
STAGING_ROOT="$(mktemp -d "$BUILD_DIR/.archive-loader-release.XXXXXX")"
trap 'rm -rf "$STAGING_ROOT"' EXIT

PAYLOAD="$STAGING_ROOT"
# Only immutable program files ship. baselines/, pristine, state/, and logs/
# are created at first run, so no extraction can destroy a user's baseline or
# mod collection.
while IFS=$'\t' read -r package_path game_path expected_hash; do
    source="$PACKAGE_ROOT/$package_path"
    [ -f "$source" ] || { echo "ERROR: missing package source: $source" >&2; exit 1; }
    actual_hash="$("$MANIFEST_CONTRACT" file-hash "$MANIFEST" "$source" "$package_path" "$game_path")"
    [ "$actual_hash" = "$expected_hash" ] || {
        echo "ERROR: package hash mismatch for $package_path" >&2
        exit 1
    }
    destination="$STAGING_ROOT/$package_path"
    mkdir -p "$(dirname "$destination")"
    cp "$source" "$destination"
done < <("$MANIFEST_CONTRACT" records "$MANIFEST")

chmod +x "$STAGING_ROOT/archive-loader/bin/archive-loader" "$STAGING_ROOT/archive-loader/setup.command" 2>/dev/null || true

( cd "$STAGING_ROOT" && zip -qry "$OUTPUT_ZIP" archive-loader )

python3 - "$OUTPUT_ZIP" "$EVIDENCE_DIR" <<'PY'
import hashlib, json, pathlib, subprocess, sys
zip_path = pathlib.Path(sys.argv[1])
evidence = pathlib.Path(sys.argv[2])
evidence.mkdir(parents=True, exist_ok=True)
listing = subprocess.check_output(["unzip", "-Z1", str(zip_path)], text=True).splitlines()
files = sorted(x for x in listing if not x.endswith("/"))
output = {
    "schema": "archive-loader-release-output/v1",
    "releaseId": zip_path.stem,
    "zipSha256": hashlib.sha256(zip_path.read_bytes()).hexdigest(),
    "zipListing": files,
}
(evidence / "release-output.json").write_text(json.dumps(output, indent=2, sort_keys=True) + "\n")
PY

echo "$OUTPUT_ZIP"
