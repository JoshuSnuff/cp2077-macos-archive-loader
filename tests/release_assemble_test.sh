#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -x "$REPOSITORY_DIR/bin/archive-loader" ] || {
    echo "ERROR: bin/archive-loader missing; build and copy it first" >&2; exit 1; }

VERSION="$("$REPOSITORY_DIR/bin/archive-loader" --version | awk '{ print $2 }')"
ZIP="$REPOSITORY_DIR/build/archive-loader-$VERSION-macos-arm64.zip"
fail() { echo "ERROR: $1" >&2; exit 1; }

rm -f "$ZIP"
produced="$("$REPOSITORY_DIR/release/assemble.sh" --version "$VERSION")" \
    || fail "assemble.sh failed"
[ "$produced" = "$ZIP" ] || fail "assemble.sh printed $produced, expected $ZIP"
[ -f "$ZIP" ] || fail "no zip was produced"

listing="$(unzip -Z1 "$ZIP" | sort)"

for required in \
    "archive-loader/setup.command" \
    "archive-loader/bin/archive-loader" \
    "archive-loader/version" \
    "archive-loader/README.txt" \
    "archive-loader/mods/enabled/.keep"; do
    printf '%s\n' "$listing" | grep -qx "$required" || fail "missing from zip: $required"
done

# The zip must contain no mutable state: an extraction can never destroy a
# baseline, a mod collection, or logs.
for forbidden in baselines pristine state logs gamefiles scripts manifests; do
    if printf '%s\n' "$listing" | grep -q "archive-loader/$forbidden"; then
        fail "the zip ships a mutable or retired directory: $forbidden"
    fi
done
if printf '%s\n' "$listing" | grep -q "install.sh"; then
    fail "the zip still ships install.sh"
fi

# A version mismatch must be refused, not shipped.
rm -f "$REPOSITORY_DIR/build/archive-loader-9.9.9-macos-arm64.zip"
if "$REPOSITORY_DIR/release/assemble.sh" --version 9.9.9 > /dev/null 2>&1; then
    fail "assemble.sh accepted a version the binary disagrees with"
fi

rm -f "$ZIP"
echo "release assemble test passed"
