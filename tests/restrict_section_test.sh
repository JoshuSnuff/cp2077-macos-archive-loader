#!/usr/bin/env bash
# Proves the shipped binary cannot be injected via DYLD_INSERT_LIBRARIES.
#
# A native binary in the launch path is unrestricted by default, so dyld loads
# the listed dylibs into it. For archive-loader that would mean RED4ext and
# Frida loading into the wrapper, and red4ext_hooks.js applying raw game-build
# offsets to our own address space. The __RESTRICT segment is what stops it,
# and this test is the only thing that would notice if the linker flag were
# dropped: nothing else observably changes.
set -euo pipefail

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="${1:-$REPOSITORY_DIR/patcher/.build/release/archive-loader}"

if [ ! -x "$BINARY" ]; then
    echo "ERROR: no binary at $BINARY" >&2
    echo "  build it with: swift build -c release --package-path patcher" >&2
    exit 1
fi

WORK_DIR="$(mktemp -d /private/tmp/archive-loader-restrict-test.XXXXXX)"
clean_up() {
    rm -rf "$WORK_DIR"
}
trap clean_up EXIT

fail() {
    echo "ERROR: $1" >&2
    exit 1
}

# --- 1. The Mach-O actually carries the segment ------------------------------
if ! otool -l "$BINARY" | grep -q "__RESTRICT"; then
    fail "$BINARY has no __RESTRICT segment; the -sectcreate linker flag is missing"
fi

# --- 2. Build a probe dylib that announces itself by writing a marker --------
cat > "$WORK_DIR/probe.c" <<'PROBE'
#include <stdio.h>
#include <stdlib.h>

__attribute__((constructor))
static void probe_loaded(void) {
    const char *marker = getenv("ARCHIVE_LOADER_PROBE_MARKER");
    if (marker == NULL) {
        return;
    }
    FILE *file = fopen(marker, "w");
    if (file != NULL) {
        fputs("loaded\n", file);
        fclose(file);
    }
}
PROBE
cc -dynamiclib -o "$WORK_DIR/probe.dylib" "$WORK_DIR/probe.c"

cat > "$WORK_DIR/control.c" <<'CONTROL'
int main(void) { return 0; }
CONTROL
cc -o "$WORK_DIR/control" "$WORK_DIR/control.c"

# Runs a command under the probe. Callers must check the returned status so a
# dyld or command failure cannot be mistaken for successful injection defence.
run_under_probe() {
    local marker="$1"
    shift
    DYLD_INSERT_LIBRARIES="$WORK_DIR/probe.dylib" \
    ARCHIVE_LOADER_PROBE_MARKER="$marker" \
        "$@" > "$WORK_DIR/stdout.txt" 2> "$WORK_DIR/stderr.txt"
}

# --- 3. Positive control: an ordinary binary IS injected ---------------------
# Without this, a broken probe would make step 4 pass for the wrong reason.
CONTROL_MARKER="$WORK_DIR/control.marker"
if run_under_probe "$CONTROL_MARKER" "$WORK_DIR/control"; then
    :
else
    control_status=$?
    echo "--- probe stderr ---" >&2
    cat "$WORK_DIR/stderr.txt" >&2
    fail "the unrestricted control binary exited with status $control_status"
fi

if [ ! -f "$CONTROL_MARKER" ]; then
    echo "--- probe stderr ---" >&2
    cat "$WORK_DIR/stderr.txt" >&2
    fail "the probe dylib did not load into an unrestricted control binary; the probe itself is broken"
fi

# --- 4. archive-loader is NOT injected --------------------------------------
LOADER_MARKER="$WORK_DIR/loader.marker"
if run_under_probe "$LOADER_MARKER" "$BINARY" --version; then
    :
else
    loader_status=$?
    echo "--- archive-loader stderr ---" >&2
    cat "$WORK_DIR/stderr.txt" >&2
    fail "archive-loader --version exited with status $loader_status under DYLD_INSERT_LIBRARIES"
fi
cp "$WORK_DIR/stdout.txt" "$WORK_DIR/version.txt"

if [ -f "$LOADER_MARKER" ]; then
    fail "the probe dylib loaded into archive-loader; __RESTRICT is not taking effect"
fi

cat > "$WORK_DIR/expected-version.txt" <<'EXPECTED_VERSION'
archive-loader 0.1.0
EXPECTED_VERSION
if ! cmp -s "$WORK_DIR/expected-version.txt" "$WORK_DIR/version.txt"; then
    echo "--- archive-loader stdout ---" >&2
    cat "$WORK_DIR/version.txt" >&2
    fail "archive-loader --version output was not exactly one line: archive-loader 0.1.0"
fi

echo "restrict section test passed"
