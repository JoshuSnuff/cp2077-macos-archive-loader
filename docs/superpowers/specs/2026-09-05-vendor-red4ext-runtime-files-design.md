# Vendor the RED4ext runtime files into the repo

Date: 2026-09-05
Status: Approved design, not yet implemented
Depends on: nothing

## Problem

Everything that makes the game load mods lives in the game directory and is
tracked by nothing. A reinstall, a store-side verify/repair, or a game patch
silently reverts all of it.

The immediate trigger: the quit-crash fix added to `red4ext_hooks.js` on
2026-09-05 exists only at
`$CP2077_GAME_DIR/red4ext/red4ext_hooks.js`. Its only backup is a `.bak` sibling
in the same directory, which the same reinstall would remove.

Current inventory of untracked game-directory files:

| File | Size | Replaceable? |
|---|---|---|
| `red4ext/red4ext_hooks.js` | 20,708 B | **No** — hand-written; hook offsets + shutdown guard |
| `red4ext/config.ini` | 273 B | No — local configuration |
| `red4ext/FridaGadget.config` | 107 B | No — local configuration |
| `red4ext/cyberpunk2077_addresses.json` | 8,995 B | No — 126 addresses for game 2.3.1 |
| `red4ext_entitlements.plist` | 487 B | No — codesigning entitlements |
| `resign_for_red4ext.sh` | 1,400 B | No — resigning procedure |
| `launch_modded.sh` (game-dir copy) | 947 B | No — diverged from the repo copy |
| `r6/scripts/*.reds` | 604 KB, 59 files | No — 20+ redscript mods |
| `red4ext/RED4ext.dylib` | 2,139,904 B | Yes — prebuilt macOS port |
| `red4ext/FridaGadget.dylib` | 59,769,808 B | Yes — upstream Frida release |
| `engine/tools/scc` + `libscc_lib.dylib` | 2.6 MB | Yes — redscript compiler |
| `engine/tools/inputloader.pl` | 6,460 B | Borderline — small, but third-party |

The `.js`, config, and `.reds` files are the irreplaceable part: roughly 640 KB of
text representing hand-tuned work. The binaries are ~64 MB and are all
redistributable third-party artifacts.

## Goals

- No hand-written or hand-configured file exists in only one place.
- A wiped game directory can be restored to a working modded state from this repo
  plus documented downloads.
- The quit-crash fix in particular survives a reinstall.

## Non-goals

- Committing large third-party binaries to git.
- Managing the game's own files (`archive/Mac/**` stays the pristine/restore
  model's concern).
- Automating installation of RED4ext or Frida from the internet.

## Design

### Layout

A new tracked directory holds the authoritative copies:

```
gamefiles/
├── README.md                  # what each file is, where binaries come from
├── red4ext/
│   ├── red4ext_hooks.js
│   ├── config.ini
│   ├── FridaGadget.config
│   └── cyberpunk2077_addresses.json
├── r6/
│   └── scripts/               # 59 .reds files
├── red4ext_entitlements.plist
└── resign_for_red4ext.sh
```

Binaries are excluded via `.gitignore` entries under `gamefiles/`, mirroring the
existing treatment of `enabled/`, `pristine/`, `logs/`, and `build/`. Their
provenance, versions, and download locations are recorded in
`gamefiles/README.md` rather than the files themselves.

The game-directory copy of `launch_modded.sh` is not vendored. It has diverged
from the repo's copy, and two launchers is the actual defect; the repo copy is
authoritative and the game-directory copy should be deleted once confirmed
redundant.

### Sync direction

The repo is authoritative. A single script, `sync_gamefiles.sh`, copies from repo
to game directory:

```bash
./sync_gamefiles.sh            # repo -> game dir, reports what changed
./sync_gamefiles.sh --check    # report differences, change nothing, exit 1 if any
./sync_gamefiles.sh --pull     # game dir -> repo, for capturing edits made in place
```

`--check` is the important mode: it detects a reinstall having reverted the hook
script, and is cheap enough to call from `launch_modded.sh` as a warning without
blocking launch. `--pull` exists because debugging naturally happens against the
live game directory; without it the repo silently goes stale, which is the same
failure in a new location.

The script follows existing conventions: `set -euo pipefail`, `CP2077_GAME_DIR`
required, quoted paths, `log()` teeing to `logs/`.

### Version coupling

`red4ext_hooks.js` and `cyberpunk2077_addresses.json` are tied to game build
2.3.1: the hook table is a list of raw `__TEXT` offsets, and the address database
names its `game_version` explicitly. A game update invalidates both, and applying
stale offsets means hooking arbitrary code.

`gamefiles/README.md` records the game version these files target.
`sync_gamefiles.sh` compares the game's `Cyberpunk2077.app` `CFBundleShortVersionString`
against that recorded version and warns loudly on mismatch. It warns rather than
refuses, because the correct response to a game update is a judgement call.

## Testing

1. `--check` on an unmodified install reports no differences and exits 0.
2. Modify `red4ext_hooks.js` in the game directory; `--check` exits 1 and names
   the file; `--pull` brings the change into the repo; `--check` returns to 0.
3. Delete `red4ext/red4ext_hooks.js` from the game directory, run the sync, and
   confirm a launch still shows `[OK] ShutdownGuard - App::Destruct neutralized`
   and exits 0 — the reinstall scenario end to end.
4. Version mismatch warning fires when the recorded version is edited to differ.
5. `git status` is clean after a sync — no binary accidentally tracked.

## Risks

- **Sync overwrites live debugging work.** Mitigated by `--check` defaulting to
  read-only and `--pull` existing as the documented capture path.
- **Repo drifts from game directory anyway** if `--pull` is forgotten. Mitigated
  by wiring `--check` into `launch_modded.sh` as a non-fatal warning, consistent
  with that script's existing `|| true` philosophy.
- **Vendored `.reds` mods diverge from their upstream sources.** Accepted: they
  are already modified in place and unversioned, so tracking them is strictly
  better than the current state.
