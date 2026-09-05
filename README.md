# cp2077-macos-archiveloader

Archive mod loader for Cyberpunk 2077 on macOS (Apple Silicon). Injects `.archive` mods into the game at launch and restores vanilla archives on exit, using APFS clonefile (`cp -c`) for instant, space-efficient copies.

> **Note:** Tested on the GOG version only. Other storefronts may work if the archive layout under `archive/Mac/` is the same.

## Setup

1. Clone this repo somewhere convenient.
2. Set the `CP2077_GAME_DIR` environment variable to your Cyberpunk 2077 install directory:
   ```bash
   export CP2077_GAME_DIR="/path/to/Cyberpunk 2077"
   ```
3. Drop your `.archive` mod files into `enabled/`.

## Usage

**Launch the game with mods:**

```bash
./launch_modded.sh
```

This is the main entry point. It runs the full modded launch sequence:

1. Restores vanilla archives from `pristine/` via APFS clone
2. Collects `.archive` mods from `enabled/` and clones them into `archive/Mac/mod/`
3. Runs `cp2077-patcher patch` to merge mods into the game's resource index
4. Runs `cp2077-patcher verify` to confirm archive integrity
5. Compiles REDscript (`engine/tools/scc`)
6. Processes input mappings (`engine/tools/inputloader.pl`)
7. Injects `RED4ext.dylib` (and `FridaGadget.dylib` if present) via `DYLD_INSERT_LIBRARIES`
8. Launches the game
9. On exit, restores vanilla archives and cleans up patcher artifacts

**Inject mods only (no launch):**

```bash
./inject_archives.sh
```

**Restore vanilla only:**

```bash
./restore_archives.sh
```

Reverts all archives to pristine state, removes patcher-generated `basegame_99_*` files, the `mod/` staging area, and `_cp2077_mac_patcher` backups.

## Directory layout

```
.
├── cp2077-patcher          # arm64 macOS patcher binary
├── launch_modded.sh        # full modded launch sequence
├── inject_archives.sh      # inject archive mods
├── restore_archives.sh     # restore vanilla archives
├── enabled/                # your .archive mod files (not tracked)
├── pristine/               # vanilla archive baselines (not tracked)
│   ├── content/
│   └── ep1/
└── logs/                   # injection/restoration logs (not tracked)
```

## Requirements

- macOS on Apple Silicon (arm64)
- APFS filesystem (default on modern macOS)
- Cyberpunk 2077 (tested on GOG)
