#!/usr/bin/env bash
# Assembles the current read-only preflight release. It writes only beneath the
# repository build directory and never touches a game installation.
set -euo pipefail

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION=""

usage() {
    cat <<EOF
Usage: $(basename "$0") --version VERSION

Assemble build/archive-loader-VERSION-macos-arm64/ with the read-only installer
and patcher discovery payload.
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

BUILD_DIR="$REPOSITORY_DIR/build"
OUTPUT_DIR="$BUILD_DIR/archive-loader-$VERSION-macos-arm64"
if [ -e "$OUTPUT_DIR" ]; then
    echo "ERROR: output already exists: $OUTPUT_DIR" >&2
    exit 1
fi
if [ ! -x "$REPOSITORY_DIR/bin/archive-loader" ]; then
    echo "ERROR: missing executable: $REPOSITORY_DIR/bin/archive-loader" >&2
    exit 1
fi

# --version is hand-typed here but compiled into the binary, and once the
# directory leaves this machine nothing else records which build it holds. A
# mislabelled release is indistinguishable from a correct one, so refuse rather
# than name the payload after a version it does not report.
BINARY_VERSION="$("$REPOSITORY_DIR/bin/archive-loader" --version)"
if [ "$BINARY_VERSION" != "archive-loader $VERSION" ]; then
    echo "ERROR: --version $VERSION disagrees with the binary, which reports: $BINARY_VERSION" >&2
    echo "  rebuild bin/archive-loader, or pass the version it was built with" >&2
    exit 1
fi

mkdir -p "$BUILD_DIR"
STAGING_ROOT="$(mktemp -d "$BUILD_DIR/.archive-loader-release.XXXXXX")"
clean_up() {
    rm -rf "$STAGING_ROOT"
}
trap clean_up EXIT

STAGING_DIR="$STAGING_ROOT/archive-loader-$VERSION-macos-arm64"
PAYLOAD_DIR="$STAGING_DIR/payload/archive-loader"
mkdir -p \
    "$PAYLOAD_DIR/bin" \
    "$PAYLOAD_DIR/scripts" \
    "$PAYLOAD_DIR/gamefiles" \
    "$PAYLOAD_DIR/manifests"

cp "$REPOSITORY_DIR/install.sh" "$STAGING_DIR/install.sh"
cp "$REPOSITORY_DIR/release/README.md" "$STAGING_DIR/README.txt"
cp "$REPOSITORY_DIR/release/payload/archive-loader/README.md" "$PAYLOAD_DIR/README.md"
cp "$REPOSITORY_DIR/bin/archive-loader" "$PAYLOAD_DIR/bin/archive-loader"

mv "$STAGING_DIR" "$OUTPUT_DIR"
echo "$OUTPUT_DIR"
