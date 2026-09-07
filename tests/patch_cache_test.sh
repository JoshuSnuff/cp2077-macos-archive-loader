#!/usr/bin/env bash
# The patched-image cache: a warm second run reuses it, and every documented
# invalidation input drops it. A cache must never change what a run produces.
set -euo pipefail

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="${1:-$REPOSITORY_DIR/patcher/.build/release/archive-loader}"
FIXTURES="$REPOSITORY_DIR/tests/fixtures"

[ -x "$BINARY" ] || { echo "ERROR: no binary at $BINARY" >&2; exit 1; }

WORK_DIR="$(mktemp -d /private/tmp/archive-loader-cache-test.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() { echo "ERROR: $1" >&2; exit 1; }

cc -o "$WORK_DIR/fakegame" "$FIXTURES/fakegame.c"
GAME_DIR="$WORK_DIR/Cyberpunk 2077"
CONTENT="$GAME_DIR/archive/Mac/content/basegame_1_engine.archive"
POST_BASELINE="$GAME_DIR/archive/Mac/content/post_baseline.archive"
MODS="$GAME_DIR/archive-loader/mods/enabled"
CACHE="$GAME_DIR/archive-loader/cache"

make_game() {
    rm -rf "$GAME_DIR"
    mkdir -p "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS" "$GAME_DIR/archive/Mac/content"
    cp "$WORK_DIR/fakegame" "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
    plutil -create xml1 "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
    plutil -insert CFBundleShortVersionString -string 2.3.1 \
        "$GAME_DIR/Cyberpunk2077.app/Contents/Info.plist"
    python3 "$FIXTURES/make_archive.py" "$CONTENT" 1111:stock-one 2222:stock-two
    "$BINARY" setup --game "$GAME_DIR" --assume-clean > /dev/null || fail "setup failed"
    # This official archive is installed after baseline capture, so its live
    # content must be part of cache invalidation rather than the baseline.
    python3 "$FIXTURES/make_archive.py" "$POST_BASELINE" 3333:official-one
    mkdir -p "$MODS"
    python3 "$FIXTURES/make_archive.py" "$MODS/a.archive" 1111:mod-one
    cat > "$GAME_DIR/launch.sh" <<'LAUNCHER'
#!/usr/bin/env bash
exec "$(dirname "$0")/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
LAUNCHER
    chmod +x "$GAME_DIR/launch.sh"
}

generations() { find "$CACHE" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '; }

# --- A first run patches and leaves a cache generation -----------------------
make_game
first="$("$BINARY" run --game "$GAME_DIR" -- ./launch.sh 2>&1)" || fail "first run failed: $first"
case "$first" in
    *"Reused the cached patched image"*) fail "the first run claimed a cache hit: $first" ;;
esac
case "$first" in
    *"Cached the patched image"*) ;;
    *) fail "the first run did not cache anything: $first" ;;
esac
[ "$(generations)" = "1" ] || fail "expected one cache generation, got $(generations)"

# --- The second run reuses it and produces an identically verified install ---
second="$("$BINARY" run --game "$GAME_DIR" -- ./launch.sh 2>&1)" || fail "second run failed: $second"
case "$second" in
    *"Reused the cached patched image"*) ;;
    *) fail "the second run did not reuse the cache: $second" ;;
esac
first_verified="$(printf '%s\n' "$first" | grep 'Verified ' || true)"
second_verified="$(printf '%s\n' "$second" | grep 'Verified ' || true)"
[ -n "$first_verified" ] || fail "the first run reported no verification"
[ "$first_verified" = "$second_verified" ] \
    || fail "a cache hit verified differently: '$first_verified' vs '$second_verified'"

# --- Both runs left the install pristine -------------------------------------
"$BINARY" status --game "$GAME_DIR" > /dev/null || fail "the install is not pristine after a cached run"

# --- A same-size post-baseline official replacement is a cache miss ----------
post_baseline_size="$(wc -c < "$POST_BASELINE" | tr -d ' ')"
python3 "$FIXTURES/make_archive.py" "$POST_BASELINE" 3333:official-two
[ "$(wc -c < "$POST_BASELINE" | tr -d ' ')" = "$post_baseline_size" ] \
    || fail "the post-baseline replacement was not the same size"
post_baseline_replaced="$("$BINARY" run --game "$GAME_DIR" -- ./launch.sh 2>&1)" \
    || fail "run after post-baseline replacement failed: $post_baseline_replaced"
case "$post_baseline_replaced" in
    *"Reused the cached patched image"*)
        fail "a same-size post-baseline replacement still hit the cache: $post_baseline_replaced" ;;
esac
case "$post_baseline_replaced" in
    *"discard"*) fail "a post-baseline cache miss discarded a generation: $post_baseline_replaced" ;;
esac
post_baseline_patch_count="$(printf '%s\n' "$post_baseline_replaced" | grep -c 'Patched ' || true)"
[ "$post_baseline_patch_count" = "1" ] \
    || fail "the post-baseline replacement patched $post_baseline_patch_count times: $post_baseline_replaced"
post_baseline_verified_count="$(printf '%s\n' "$post_baseline_replaced" | grep -c 'Verified ' || true)"
[ "$post_baseline_verified_count" = "1" ] \
    || fail "the post-baseline replacement verified $post_baseline_verified_count times: $post_baseline_replaced"
case "$post_baseline_replaced" in
    *"vanilla-on-error"*) fail "a post-baseline cache miss triggered vanilla fallback: $post_baseline_replaced" ;;
esac
"$BINARY" status --game "$GAME_DIR" > /dev/null \
    || fail "the install is not pristine after a post-baseline replacement"

# --- Editing a mod invalidates ------------------------------------------------
python3 "$FIXTURES/make_archive.py" "$MODS/a.archive" 1111:mod-one-edited
edited="$("$BINARY" run --game "$GAME_DIR" -- ./launch.sh 2>&1)" || fail "run after edit failed: $edited"
case "$edited" in
    *"Reused the cached patched image"*) fail "an edited mod still hit the cache: $edited" ;;
esac

# --- Adding a mod invalidates -------------------------------------------------
python3 "$FIXTURES/make_archive.py" "$MODS/b.archive" 2222:mod-two
added="$("$BINARY" run --game "$GAME_DIR" -- ./launch.sh 2>&1)" || fail "run after add failed: $added"
case "$added" in
    *"Reused the cached patched image"*) fail "an added mod still hit the cache: $added" ;;
esac

# --- Retention keeps at most two generations ---------------------------------
[ "$(generations)" -le 2 ] || fail "cache retention kept $(generations) generations"

# --- --no-cache neither reads nor writes -------------------------------------
"$BINARY" run --game "$GAME_DIR" -- ./launch.sh > /dev/null 2>&1 || fail "warming run failed"
before="$(generations)"
skipped="$("$BINARY" run --no-cache --game "$GAME_DIR" -- ./launch.sh 2>&1)" \
    || fail "--no-cache run failed: $skipped"
if printf '%s\n' "$skipped" | grep -Eq 'Cached the patched image|Reused the cached patched image|cache fingerprint|could not (fingerprint|look up|apply|cache)'; then
    fail "--no-cache still mentioned or consulted the cache: $skipped"
fi
[ "$(generations)" = "$before" ] || fail "--no-cache changed the cache"

# --- A truncated generation is a miss, not a hit ------------------------------
# The size recorded in cache.json no longer matches, so lookUp rejects it
# before a single byte is cloned.
"$BINARY" run --game "$GAME_DIR" -- ./launch.sh > /dev/null 2>&1 || fail "warming run failed"
find "$CACHE" -name '*.archive' -exec sh -c 'printf corrupt > "$1"' _ {} \;
truncated="$("$BINARY" run --game "$GAME_DIR" -- ./launch.sh 2>&1)" \
    || fail "a truncated cache failed the launch: $truncated"
case "$truncated" in
    *"Reused the cached patched image"*) fail "a truncated generation was treated as a hit: $truncated" ;;
esac
"$BINARY" status --game "$GAME_DIR" > /dev/null \
    || fail "the install is not pristine after a truncated-cache run"

# --- A same-size scribble reaches PlanVerifier and retries once ----------------
# Cache lookup checks size only; semantic correctness remains PlanVerifier's
# gate, which discards the bad generation and performs one bounded retry.
"$BINARY" run --game "$GAME_DIR" -- ./launch.sh > /dev/null 2>&1 || fail "warming run failed"
find "$CACHE" -name '*.archive' -exec \
    dd if=/dev/zero of={} bs=1 count=4 conv=notrunc status=none \;
scribbled="$("$BINARY" run --game "$GAME_DIR" -- ./launch.sh 2>&1)" \
    || fail "a scribbled cache failed the launch: $scribbled"
case "$scribbled" in
    *"Reused the cached patched image"*) ;;
    *) fail "a same-size damaged generation did not reach the verifier: $scribbled" ;;
esac
case "$scribbled" in
    *"discard"*) ;;
    *) fail "a bad cache was not discarded after verification: $scribbled" ;;
esac
patched_fallback_count="$(printf '%s\n' "$scribbled" | grep -c 'Patched ' || true)"
[ "$patched_fallback_count" = "1" ] \
    || fail "the same-size cache miss patched $patched_fallback_count times: $scribbled"
verified_fallback_count="$(printf '%s\n' "$scribbled" | grep -c 'Verified ' || true)"
[ "$verified_fallback_count" = "1" ] \
    || fail "the bad cache path verified $verified_fallback_count times: $scribbled"
case "$scribbled" in
    *"vanilla-on-error"*) fail "a bad cache triggered vanilla fallback: $scribbled" ;;
esac
"$BINARY" status --game "$GAME_DIR" > /dev/null \
    || fail "the install is not pristine after a same-size cache miss"

# --- A rebaseline drops the cache -------------------------------------------
"$BINARY" run --game "$GAME_DIR" -- ./launch.sh > /dev/null 2>&1 || fail "warming run failed"
[ "$(generations)" -ge 1 ] || fail "no cache to invalidate"
"$BINARY" setup --game "$GAME_DIR" --rebaseline --assume-clean > /dev/null \
    || fail "rebaseline failed"
[ "$(generations)" = "0" ] || fail "a rebaseline left $(generations) cache generations"

# --- status reports the cache without treating it as evidence ----------------
"$BINARY" run --game "$GAME_DIR" -- ./launch.sh > /dev/null 2>&1 || fail "warming run failed"
status_output="$("$BINARY" status --game "$GAME_DIR")" \
    || fail "status failed while a cache generation existed"
case "$status_output" in
    *"Live        pristine"*) ;;
    *) fail "a cache generation made status report a non-pristine install: $status_output" ;;
esac
case "$status_output" in
    *"Cache"*) ;;
    *) fail "status did not mention the cache: $status_output" ;;
esac

# --- cache clear is the escape hatch -----------------------------------------
if "$BINARY" cache clear --game "$GAME_DIR" --unexpected > /dev/null 2>&1; then
    fail "cache clear accepted an unknown option"
fi
if "$BINARY" cache clear --game > /dev/null 2>&1; then
    fail "cache clear accepted a missing --game value"
fi
[ "$(generations)" -ge 1 ] || fail "malformed cache clear removed the cache"
"$BINARY" cache clear --game "$GAME_DIR" > /dev/null || fail "cache clear failed"
[ "$(generations)" = "0" ] || fail "cache clear left $(generations) generations"
"$BINARY" cache clear --game "$GAME_DIR" > /dev/null || fail "cache clear is not idempotent"

echo "patch cache test passed"
