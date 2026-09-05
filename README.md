# cp2077-macos-archiveloader

Archive mod loader for Cyberpunk 2077 on macOS (Apple Silicon). Injects `.archive` mods into the game and restores pristine originals when needed, using APFS clonefile for instant, space-efficient copies.

> **Note:** Tested on the GOG version only. Other storefronts may work if the archive layout under `archive/Mac/` is the same.

## Setup

1. Clone this repo somewhere convenient.
2. Set the `CP2077_GAME_DIR` environment variable to your Cyberpunk 2077 install directory:
   ```bash
   export CP2077_GAME_DIR="/path/to/Cyberpunk 2077"
   ```
3. Copy the vanilla game archives you plan to mod into `pristine/`:
   - `pristine/content/` — base game archives from `archive/Mac/content/`
   - `pristine/ep1/` — Phantom Liberty archives from `archive/Mac/ep1/`
4. Drop your `.archive` mod files into `enabled/`.

## Usage

**Launch the game with mods:**

```bash
./launch_modded.sh
```

Full modded launch sequence — injects archive mods, compiles REDscript, processes input mappings, loads RED4ext via `DYLD_INSERT_LIBRARIES`, launches the game, and restores pristine archives on exit. Set this as your custom launch command in Heroic or whatever launcher you use.

**Inject mods only:**

```bash
./inject_archives.sh
```

Restores pristine archives first, then stages mods into the game's `archive/Mac/mod/` directory and runs `cp2077-patcher` to patch them in. If patching fails, pristine archives are automatically restored so the game launches vanilla.

**Restore vanilla:**

```bash
./restore_archives.sh
```

Reverts all modified archives to their pristine state and removes any loose patcher-generated files.

## How it works

`launch_modded.sh` runs these steps in order:

1. **Restore** — APFS-clones (`cp -c`) each file from `pristine/` back to the game directory, then removes any `basegame_99_*` loose files and the `mod/` staging area left by a previous run.
2. **Stage** — APFS-clones every `.archive` from `enabled/` into `archive/Mac/mod/`.
3. **Patch** — Runs `cp2077-patcher patch --game <dir> --mods <files>` to merge mod archives into the game's resource index.
4. **Verify** — Runs `cp2077-patcher verify` to confirm archive integrity.
5. **REDscript** — Compiles scripts via `engine/tools/scc`.
6. **Input mappings** — Processes custom bindings via `engine/tools/inputloader.pl`.
7. **RED4ext** — Injects `RED4ext.dylib` (and `FridaGadget.dylib` if present) via `DYLD_INSERT_LIBRARIES`.
8. **Launch** — Starts the game, waits for exit.
9. **Cleanup** — Restores pristine archives so the game directory is always vanilla at rest.

## Directory layout

```
.
├── cp2077-patcher          # arm64 macOS patcher binary
├── launch_modded.sh        # full modded launch sequence
├── inject_archives.sh      # inject archive mods
├── restore_archives.sh     # restore vanilla archives
├── enabled/                # your .archive mod files (not tracked)
├── pristine/               # vanilla archive backups (not tracked)
│   ├── content/
│   └── ep1/
└── logs/                   # injection/restoration logs (not tracked)
```

## Requirements

- macOS on Apple Silicon (arm64)
- APFS filesystem (default on modern macOS)
- Cyberpunk 2077 (tested on GOG)
