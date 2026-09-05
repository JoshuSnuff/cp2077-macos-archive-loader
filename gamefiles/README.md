# Vendored game runtime files

Target game version: 2.3.1

This directory is the authoritative copy of the hand-written and locally
configured files used by the macOS RED4ext runtime. The hook offsets and address
database are coupled to the target game version above. Do not assume they are
safe after a game update.

## Managed files

- `red4ext/red4ext_hooks.js` — Frida hooks, including the shutdown guard.
- `red4ext/config.ini` and `red4ext/FridaGadget.config` — local runtime config.
- `red4ext/cyberpunk2077_addresses.json` — 126-address database for game 2.3.1.
- `red4ext_entitlements.plist` and `resign_for_red4ext.sh` — the local signing
  configuration and procedure.

Personal REDscript mods under `r6/scripts/` are intentionally ignored and are
not synchronized or published by this repository.

Use the repository-root sync script to compare or transfer them:

```bash
export CP2077_GAME_DIR="/path/to/Cyberpunk 2077"
./sync_gamefiles.sh --check
./sync_gamefiles.sh
./sync_gamefiles.sh --pull
```

The no-option form copies repository files into the game. `--pull` captures
edits made against the live installation. Both directions are limited to the
RED4ext runtime files listed above.

## Third-party runtime downloads

These files are intentionally not committed. Download or build them and install
them at the listed game-relative paths:

| Game-relative files | Recorded version | Source |
|---|---|---|
| `red4ext/RED4ext.dylib` | `1.29.1+master.c70ed4a.20251231T213753Z` | [RED4ext macOS port](https://github.com/memaxo/RED4ext-macos), built from [upstream RED4ext 1.29.1](https://github.com/WopsS/RED4ext/releases/tag/v1.29.1) |
| `red4ext/FridaGadget.dylib` | `17.5.2`, macOS universal | [Frida 17.5.2 release asset](https://github.com/frida/frida/releases/download/17.5.2/frida-gadget-17.5.2-macos-universal.dylib.xz) |
| `engine/tools/scc`, `engine/tools/libscc_lib.dylib` | `0.5.31` | [redscript 0.5.31 for macOS](https://github.com/jac3km4/redscript/releases/download/v0.5.31/redscript-v0.5.31-macos.zip) |
| `engine/tools/inputloader.pl` | `1.0` | [Input Loader for macOS 1.0](https://github.com/risner/cyberpunk2077-input-loader-mac/releases/tag/v1.0) |

The RED4ext macOS installer downloads Frida and installs the RED4ext runtime.
Downloaded dylibs may need quarantine removal and ad-hoc signing. After restoring
these dependencies, run the tracked `resign_for_red4ext.sh` from the game root.

The repository's `launch_modded.sh` is the only launcher. Do not restore the old
game-root copy; it bypasses repository configuration and can drift independently.
