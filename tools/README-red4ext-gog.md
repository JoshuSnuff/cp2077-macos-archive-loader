# RED4ext GOG runtime probe

`red4ext_gog_trace.js` is an optional, read-only Frida Gadget probe for the
installed macOS GOG build. It does not replace functions, write process memory,
or use the Steam offsets in `gamefiles/red4ext/red4ext_hooks.js`. It attaches
only to candidates emitted by `red4ext_gog_audit.py` and writes bounded,
newline-delimited JSON observations.

The probe is diagnostic evidence, not a database generator. Do not copy an
observation into `cyberpunk2077_addresses.json` by hand; run the guarded Task 3
generator after all static and runtime evidence has been collected.

## Prepare an audit

Run the analyzer against the exact executable in the existing GOG install. The
audit file may live outside the repository:

```bash
REPOSITORY_DIR="/path/to/CP2077 Archive Runtime"
GAME_DIR="/path/to/Cyberpunk 2077"
AUDIT_JSON="/private/tmp/cp2077-gog-audit.json"
TRACE_JSONL="/private/tmp/cp2077-gog-trace.ndjson"

python3 "$REPOSITORY_DIR/tools/red4ext_gog_audit.py" \
    "$GAME_DIR/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077" \
    --json "$AUDIT_JSON"
```

The analyzer must finish successfully and produce candidates. An empty or
incomplete audit is safe: the probe skips missing hooks and never substitutes a
Steam address.

## Temporarily select the probe

Frida Gadget loads the script named by `red4ext/FridaGadget.config`. Make a
recoverable copy of the normal configuration, copy the probe beside it, and
change only the script path:

```bash
[ ! -e "$GAME_DIR/red4ext/FridaGadget.config.before-gog-trace" ] || \
    { echo "ERROR: an older GOG trace backup already exists; restore it first" >&2; exit 1; }
[ ! -e "$GAME_DIR/red4ext/red4ext_gog_trace.js" ] || \
    { echo "ERROR: red4ext_gog_trace.js already exists; preserve it before probing" >&2; exit 1; }
cp "$GAME_DIR/red4ext/FridaGadget.config" \
   "$GAME_DIR/red4ext/FridaGadget.config.before-gog-trace"
cp "$REPOSITORY_DIR/tools/red4ext_gog_trace.js" \
   "$GAME_DIR/red4ext/red4ext_gog_trace.js"
sed -i '' 's#\./red4ext_hooks\.js#\./red4ext_gog_trace\.js#' \
    "$GAME_DIR/red4ext/FridaGadget.config"
```

The probe reads these environment variables inside the game process:

| Variable | Meaning |
|---|---|
| `RED4EXT_GOG_AUDIT_JSON` | Analyzer JSON path; required to enable candidate attachment |
| `RED4EXT_GOG_TRACE_OUTPUT` | NDJSON output path; empty means Frida console output |
| `RED4EXT_GOG_MAX_OBSERVATIONS` | Optional positive cap; default is 256 |

## Launch the existing GOG setup

Keep the normal archive-loader wrapper and the existing `launch_modded.sh` in
the launch path. The RED4ext injection is opt-in and remains owned by that
launcher:

```bash
export ARCHIVE_LOADER_GAME_DIR="$GAME_DIR"
export ARCHIVE_LOADER_RED4EXT=1
export RED4EXT_GOG_AUDIT_JSON="$AUDIT_JSON"
export RED4EXT_GOG_TRACE_OUTPUT="$TRACE_JSONL"

cd "$GAME_DIR"
./archive-loader/bin/archive-loader run -- ./launch_modded.sh
```

Inspect `$TRACE_JSONL` after the game exits. Every `observation` record includes
the hook name, hash, analyzer candidate RVA, per-candidate call count, captured
argument pointers, selected strings that passed bounded safe reads, and the
return value. `attach_error`, `hook_missing`, and `candidate_rejected` records
are evidence that must remain unresolved rather than being treated as success.

## Restore the normal Frida configuration

Restore the saved config before any ordinary launch. The probe copy is not part
of the normal runtime and can then be removed. If the copy was made over an
existing file, restore that file from your own backup instead of deleting it.

```bash
cp "$GAME_DIR/red4ext/FridaGadget.config.before-gog-trace" \
   "$GAME_DIR/red4ext/FridaGadget.config"
rm "$GAME_DIR/red4ext/FridaGadget.config.before-gog-trace"
rm "$GAME_DIR/red4ext/red4ext_gog_trace.js"
unset ARCHIVE_LOADER_RED4EXT
unset RED4EXT_GOG_AUDIT_JSON RED4EXT_GOG_TRACE_OUTPUT RED4EXT_GOG_MAX_OBSERVATIONS
```

If a launch is interrupted, perform this restore first. The archive-loader
wrapper still owns archive restoration; the probe never changes archive files or
the game executable.
