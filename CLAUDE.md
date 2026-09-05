# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Bash + prebuilt-binary mod loader for Cyberpunk 2077 on macOS/Apple Silicon. There is no build step and no test suite — the deliverable is three shell scripts plus `cp2077-patcher` (an arm64 Mach-O built from Swift sources in a `CP2077ArchiveCore` package that is **not** in this repo).

`CP2077_GAME_DIR` must be exported for any script to run; all three exit 1 without it.

```bash
export CP2077_GAME_DIR="/path/to/Cyberpunk 2077"
./launch_modded.sh      # full sequence: inject → scc → inputloader → RED4ext → game → restore
./inject_archives.sh    # inject only (safe to run standalone for testing)
./restore_archives.sh   # restore vanilla only (use this to recover after a crash)
```

Patcher CLI (invoked by `inject_archives.sh`, but useful directly when debugging a single mod):

```bash
./cp2077-patcher scan MOD.archive [...]
./cp2077-patcher detect
./cp2077-patcher verify --game "$CP2077_GAME_DIR"
./cp2077-patcher patch --game "$CP2077_GAME_DIR" [--strategy hybrid|aggressive] [--target T.archive] --mods MOD.archive [...]
./cp2077-patcher restore --game "$CP2077_GAME_DIR" [--backup BACKUP_DIR | --latest]
```

Every run writes a timestamped log to `logs/`; override the path with `INJECT_LOG_FILE` / `RESTORE_LOG_FILE`.

## Why the design looks like this

The game has no mod-loading hook on macOS. The patcher's default `hybrid` strategy **rewrites the shipped official archives in place** inside `$CP2077_GAME_DIR/archive/Mac/{content,ep1}/`, and spills whatever can't be merged into loose `basegame_99_*.archive` files alongside them. So a patched install is a destroyed install until something puts the originals back.

That single fact drives everything else:

- **`pristine/{content,ep1}/` is the only copy of vanilla.** It is gitignored (only `.gitkeep` is tracked) and **no script ever writes to it** — it must be populated by hand from a clean install before first use. Losing it means reinstalling the game.
- **Every injection starts by restoring**, not by patching. `inject_archives.sh` calls `restore_pristine` up front so a crashed prior session can't stack a second patch on already-patched archives, and calls it again if the patcher fails, so the game still launches vanilla rather than broken.
- **`cp -c` (APFS clonefile) everywhere.** Restoring all 57 archives is near-instant and costs no disk, which is what makes restore-before-every-run affordable.

Cleanup has to sweep four distinct kinds of patcher artifact, and any change to one restore path must be mirrored in the other:

| Artifact | Handled by |
|---|---|
| Rewritten official archives | clone back from `pristine/` |
| `basegame_99_*` loose archives | delete from `content/` and `ep1/` |
| `archive/Mac/mod/` staging dir | delete |
| `archive/Mac/_cp2077_mac_patcher/backups/` | delete — **only `restore_archives.sh` does this** |

`restore_pristine()` in `inject_archives.sh:25` is a deliberate near-duplicate of `restore_archives.sh` minus that last row (the backups are still needed mid-session). Keep the two in sync when editing either.

## Launch sequence notes

`launch_modded.sh` suffixes every step with `|| true` on purpose: a failed REDscript compile or missing inputloader must not stop the game from launching. It deliberately does **not** `exec` the game, because it has to regain control afterwards to restore.

The post-exit restore runs from an `EXIT` trap, not a trailing line, because `set -e` would otherwise abort the script on a non-zero game exit and leave the install patched — exactly the crash case where restore matters most. Keep it that way: the launch call must stay `|| game_exit=$?` (never bare), and the `INT`/`TERM` traps exist so a Ctrl-C converts to a normal `exit` that still fires the `EXIT` trap. `restored` guards against the trap running twice. Verified against clean exit, non-zero exit, SIGSEGV, and Ctrl-C.

If a restore is ever missed anyway (e.g. `SIGKILL`), `./restore_archives.sh` is the manual recovery, and the next `inject_archives.sh` restores first regardless.

RED4ext is injected via `DYLD_INSERT_LIBRARIES` with `DYLD_FORCE_FLAT_NAMESPACE=1`; `FridaGadget.dylib` is appended only if present.

## Conventions

- Mods are dropped in `enabled/` as plain `.archive` files; load order is the `sort -z` order of that listing, which is why real mod names carry `#`/`0_`/`x_` prefixes to force position. Preserve the NUL-delimited `find | sort -z` read loop — mod filenames contain spaces.
- `enabled/`, `pristine/`, `logs/`, `build/` are gitignored except for `.gitkeep`. Do not commit archives or logs.
- Scripts are `set -euo pipefail`, quote all paths (`$GAME_DIR` contains a space in normal installs), and log through `log()` which tees to both stdout and the log file.
