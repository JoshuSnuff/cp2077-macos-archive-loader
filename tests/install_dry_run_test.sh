#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${1:-$REPOSITORY_DIR/install.sh}"
FIXTURE_DIR="$(mktemp -d /private/tmp/archive-loader-install-test.XXXXXX)"
GAME_DIR="$FIXTURE_DIR/Game With Spaces"

clean_up() {
    rm -rf "$FIXTURE_DIR"
}
trap clean_up EXIT

mkdir -p \
    "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS" \
    "$GAME_DIR/archive/Mac/content" \
    "$GAME_DIR/archive/Mac/ep1"
touch \
    "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077" \
    "$GAME_DIR/archive/Mac/content/basegame_1_fixture.archive"
chmod +x "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
plutil -create xml1 "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string 2.3.1 \
    "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"

snapshot() {
    find "$GAME_DIR" -print0 | LC_ALL=C sort -z | while IFS= read -r -d '' path; do
        if [ -f "$path" ]; then
            shasum -a 256 "$path"
        else
            echo "$path"
        fi
    done
}

before="$(snapshot)"
output="$("$INSTALLER" --dry-run --game "$GAME_DIR")"
after="$(snapshot)"

if [ "$before" != "$after" ]; then
    echo "ERROR: installer dry-run changed the fixture" >&2
    exit 1
fi

case "$output" in
    *"Preflight passed."*) ;;
    *)
        echo "ERROR: installer dry-run did not report success" >&2
        echo "$output" >&2
        exit 1
        ;;
esac
case "$output" in
    *"No files were changed."*) ;;
    *)
        echo "ERROR: installer dry-run did not report read-only behavior" >&2
        echo "$output" >&2
        exit 1
        ;;
esac

echo "installer dry-run fixture test passed"
