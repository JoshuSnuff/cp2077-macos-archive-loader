# cp2077-macos-archiveloader

Archive mod loader for Cyberpunk 2077 on macOS (Apple Silicon). Injects `.archive` mods into the game and restores pristine originals when needed, using APFS clonefile for instant, space-efficient copies.

## Setup

1. Clone this repo into your Heroic Games Launcher directory (alongside the game).
2. Copy the vanilla game archives you plan to mod into `pristine/`:
   - `pristine/content/` — base game archives from `archive/Mac/content/`
   - `pristine/ep1/` — Phantom Liberty archives from `archive/Mac/ep1/`
3. Drop your `.archive` mod files into `enabled/`.

## Usage

**Inject mods:**

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

1. **Restore** — APFS-clones (`cp -c`) each file from `pristine/` back to the game directory, then removes any `basegame_99_*` loose files and the `mod/` staging area left by a previous run.
2. **Stage** — APFS-clones every `.archive` from `enabled/` into `archive/Mac/mod/`.
3. **Patch** — Runs `cp2077-patcher patch --game <dir> --mods <files>` to merge mod archives into the game's resource index.
4. **Verify** — Runs `cp2077-patcher verify` to confirm archive integrity.

## Directory layout

```
.
├── cp2077-patcher          # arm64 macOS patcher binary
├── inject_archives.sh      # inject mods into the game
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
- Cyberpunk 2077 installed via Heroic Games Launcher
