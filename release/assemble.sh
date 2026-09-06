#!/usr/bin/env bash
# Assembles the current read-only preflight release. It writes only beneath the
# repository build directory and never touches a game installation.
set -euo pipefail

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

BUILD_DIR="$REPOSITORY_DIR/build"
OUTPUT_ZIP="$BUILD_DIR/archive-loader-$VERSION-macos-arm64.zip"
BINARY="$REPOSITORY_DIR/bin/archive-loader"

if [ -e "$OUTPUT_ZIP" ]; then
    echo "ERROR: output already exists: $OUTPUT_ZIP" >&2
    exit 1
fi
if [ ! -x "$BINARY" ]; then
    echo "ERROR: missing executable: $BINARY" >&2
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

PAYLOAD="$STAGING_ROOT/archive-loader"
# Only immutable program files ship. baselines/, pristine, state/, and logs/
# are created at first run, so no extraction can destroy a user's baseline or
# mod collection.
mkdir -p "$PAYLOAD/bin" "$PAYLOAD/mods/enabled"

cp "$BINARY" "$PAYLOAD/bin/archive-loader"
cp "$REPOSITORY_DIR/release/payload/archive-loader/setup.sh" "$PAYLOAD/setup.sh"
cp "$REPOSITORY_DIR/release/payload/archive-loader/README.txt" "$PAYLOAD/README.txt"
printf '%s\n' "$VERSION" > "$PAYLOAD/version"
touch "$PAYLOAD/mods/enabled/.keep"

chmod +x "$PAYLOAD/setup.sh" "$PAYLOAD/bin/archive-loader"

( cd "$STAGING_ROOT" && zip -qry "$OUTPUT_ZIP" archive-loader )

echo "$OUTPUT_ZIP"
