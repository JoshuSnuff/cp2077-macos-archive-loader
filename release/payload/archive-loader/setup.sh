#!/usr/bin/env bash
# archive-loader installer entry point.
#
# This is bash rather than part of the binary for one reason: Archive Utility
# marks everything it extracts with com.apple.quarantine, and Gatekeeper blocks
# a quarantined binary on first execution however it is invoked. Shell scripts
# are not gated the same way, so this clears the attribute and then runs the
# binary. It never launches the game, so being a script is safe here.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A merge hands us the sibling to delete rather than deleting it itself: bash
# reads a script incrementally, so removing the file that is currently
# executing can truncate it mid-run.
if [ -n "${ARCHIVE_LOADER_REMOVE_SIBLING:-}" ]; then
    rm -rf "$ARCHIVE_LOADER_REMOVE_SIBLING"
    unset ARCHIVE_LOADER_REMOVE_SIBLING
fi

# --- Merge an Archive Utility re-extraction ---------------------------------
# Archive Utility does not merge folders: extracting an upgrade beside an
# existing install produces "archive-loader 2", leaving the old binary in the
# launch path and the new one inert. Users double-click, so the release cannot
# assume a merging extractor.
merge_into_existing_install() {
    local here_name parent existing
    here_name="$(basename "$HERE")"
    parent="$(dirname "$HERE")"

    case "$here_name" in
        "archive-loader "[0-9]*) ;;
        *) return 0 ;;
    esac

    existing="$parent/archive-loader"
    [ -d "$existing" ] || return 0

    echo "Found an existing install at $existing"
    echo "Upgrading it from $here_name and removing the duplicate..."

    # Only the immutable program files. baselines/, pristine, state/, mods/,
    # and logs/ are the user's and are never touched.
    rm -rf "$existing/bin"
    cp -R "$HERE/bin" "$existing/bin"
    cp "$HERE/setup.sh" "$existing/setup.sh"
    cp "$HERE/version" "$existing/version"
    [ -f "$HERE/README.txt" ] && cp "$HERE/README.txt" "$existing/README.txt"

    chmod +x "$existing/setup.sh" "$existing/bin/archive-loader"

    echo ""
    cd "$parent"
    ARCHIVE_LOADER_REMOVE_SIBLING="$HERE" exec "$existing/setup.sh" "$@"
}
merge_into_existing_install "$@"

# --- Clear quarantine -------------------------------------------------------
has_quarantine() {
    local path
    while IFS= read -r -d '' path; do
        if xattr -p com.apple.quarantine "$path" > /dev/null 2>&1; then
            return 0
        fi
    done < <(find "$HERE" -print0)
    return 1
}

clear_quarantine() {
    local path
    while IFS= read -r -d '' path; do
        xattr -d com.apple.quarantine "$path" > /dev/null 2>&1 || true
    done < <(find "$HERE" -print0)
}

if has_quarantine; then
    echo "Clearing com.apple.quarantine from $HERE"
    echo "  (Archive Utility marks everything it extracts; Gatekeeper would"
    echo "   otherwise block the binary on first run.)"
    clear_quarantine
    echo ""
fi

chmod +x "$HERE/bin/archive-loader"

if [ ! -x "$HERE/bin/archive-loader" ]; then
    echo "ERROR: $HERE/bin/archive-loader is missing or not executable" >&2
    echo "  Re-extract the zip and try again." >&2
    exit 1
fi

exec "$HERE/bin/archive-loader" setup "$@"
