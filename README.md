# cp2077-macos-archiveloader

Archive mod loader for Cyberpunk 2077 on macOS (Apple Silicon).

Cyberpunk 2077 has no mod-loading hook on macOS. This repo works around that with
four Bash scripts and a Swift binary that rewrites the game's own archives
before launch and puts the originals back afterwards.

> Tested against the GOG build, game version 2.3.1, on Apple Silicon. Other
> storefronts may work if the layout under `archive/Mac/` matches.

## Status

Last verified 2026-09-06 against game 2.3.1 with 33 mods enabled.

| Capability | State |
|---|---|
| `.archive` mods that add new resources | Working |
| `.archive` mods that override stock resources | Working — every record verified against the patch plan |
| REDscript mods (`r6/scripts`) | Working when installed locally |
| Input remapping (`inputloader.pl`) | Working |
| Restore-to-vanilla on every exit path | Working — verified against clean exit, non-zero exit, SIGSEGV, and Ctrl-C |
| Crash on quit | Fixed 2026-09-05 (see RED4ext below) |
| RED4ext native plugins | **Not working** — no plugin can load |
| ArchiveXL / TweakXL / CET | **Not supported** — blocked on the above |
| `.archive.xl` sidecars | **Not supported** |

This is an archive-only mod loader plus REDscript. It is not an ArchiveXL
replacement and cannot become one without reviving RED4ext's native hooking.

## How it works

The patcher's `hybrid` strategy **rewrites the shipped official archives in
place** in `$CP2077_GAME_DIR/archive/Mac/{content,ep1}/`, and spills resources
that don't exist in any official archive into loose `basegame_99_*.archive` files
alongside them.

A patched install is a destroyed install until something puts the originals back.
Everything else follows from that:

- **`pristine/{content,ep1}/` is the only copy of vanilla.** 57 archives, 32 in
  `content/` and 25 in `ep1/`. It is gitignored and **no script ever writes to
  it** — populate it by hand from a clean install before first use. Losing it
  means reinstalling the game.
- **Every injection restores first.** `inject_archives.sh` calls
  `restore_pristine` before patching, so a crashed prior session can't stack a
  second patch onto already-patched archives, and again if the patcher fails, so
  the game still launches vanilla rather than broken.
- **Restore runs from an `EXIT` trap**, not a trailing line, so a crash or Ctrl-C
  can't leave the install patched.
- **`cp -c` (APFS clonefile) everywhere.** Restoring all 57 archives is
  near-instant and costs no disk, which is what makes restore-before-every-run
  affordable.

### Why overrides require rewriting official archives

Two probe launches on 2026-09-05 established the platform's rules. A pure-override
mod was installed as a single loose archive with all official archives left
pristine:

| Probe filename | Sorts | Override applied? |
|---|---|---|
| `0_probe_sasha.archive` | before all official archives | No |
| `basegame_99_probe_sasha.archive` | after all official archives | No |

Meanwhile new-content mods delivered through `basegame_99_*` load fine.

**A loose archive on macOS can add new resources but can never override a
resource an official archive already owns, at any sort position.** Windows'
`archive/pc/mod/` scope has no macOS equivalent. Rewriting official archives is
the only override mechanism available, so parity with Windows means matching its
observable outcome, not its mechanism.

## Setup

1. Clone this repo.
2. Point `CP2077_GAME_DIR` at your install:
   ```bash
   export CP2077_GAME_DIR="/path/to/Cyberpunk 2077"
   ```
   All four scripts exit 1 without it.
3. Populate `pristine/content/` and `pristine/ep1/` by hand from a **clean**
   install. Nothing does this for you and nothing will warn you.
4. Restore the tracked RED4ext runtime files into the game:
   ```bash
   ./sync_gamefiles.sh
   ```
5. Drop `.archive` mods into `enabled/`.

The third-party RED4ext, Frida, redscript compiler, and Input Loader files are
not committed. See [`gamefiles/README.md`](gamefiles/README.md) for their pinned
versions and download locations.

Load order is the `sort -z` order of `enabled/`, which is why real mod names carry
`#`, `0_`, or `x_` prefixes to force position.

## Usage

```bash
./launch_modded.sh           # check → inject → compile → game → restore
./inject_archives.sh         # inject only (safe standalone, for testing)
./restore_archives.sh        # restore vanilla only (manual crash recovery)
./sync_gamefiles.sh --check  # report RED4ext drift without changing files
./sync_gamefiles.sh          # copy tracked RED4ext files from repo to game
./sync_gamefiles.sh --pull   # capture live RED4ext edits into the repo
```

`launch_modded.sh` runs the runtime-file check as a non-fatal warning. It also
suffixes injection, REDscript compilation, and input loading with `|| true` on
purpose: those failures must not stop the game launching. It deliberately does
not `exec`, because it has to regain control to restore.

If a restore is ever missed anyway (`SIGKILL`, power loss), `./restore_archives.sh`
is the manual recovery, and the next `inject_archives.sh` restores first
regardless.

Every run writes a timestamped log to `logs/`; override with `INJECT_LOG_FILE`,
`RESTORE_LOG_FILE`, or `SYNC_LOG_FILE`.

## The patcher

`cp2077-patcher` is an arm64 Mach-O built from the Swift package in `patcher/`.
The binary at the repo root is a build artifact of that source, checked in so the
loader works without a Swift toolchain:

```bash
swift build -c release --package-path patcher
cp patcher/.build/release/cp2077-patcher .
swift test --package-path patcher      # 32 tests, no game install needed
```

The package originates from
[brunoformagio/cp2077-mac-archive-patcher](https://github.com/brunoformagio/cp2077-mac-archive-patcher)
(MIT) at commit `f619246`, vendored here and modified since. Upstream's README is
kept verbatim as `patcher/README.upstream.md` and its licence as
`patcher/LICENSE`.

CLI, invoked by `inject_archives.sh` but useful directly when debugging one mod:

```bash
./cp2077-patcher scan MOD.archive [...]
./cp2077-patcher detect
./cp2077-patcher verify --game "$CP2077_GAME_DIR" [--mods MOD.archive [...]]
./cp2077-patcher patch --game "$CP2077_GAME_DIR" [--strategy hybrid|aggressive] [--target T.archive] --mods MOD.archive [...]
./cp2077-patcher restore --game "$CP2077_GAME_DIR" [--backup BACKUP_DIR | --latest]
```

`patch` builds **one plan** across every `--mods` argument before writing
anything, and `verify --mods` recomputes that plan and checks the install against
it record by record. Without `--mods`, `verify` can only check archive structure,
because with no plan a patched record cannot be told from a stock one.

## RED4ext and REDscript

REDscript works normally. RED4ext loads, but **its native hooking is dead**: all
seven function hashes it needs are absent from `cyberpunk2077_addresses.json`,
every `DetourAttach` fails with a null pointer, and `red4ext/plugins/` is empty.
No native plugin — ArchiveXL, TweakXL, CET — can load.

What does work is a parallel Frida hook layer (`red4ext/red4ext_hooks.js`, 8 of 14
hooks active). Its `ScriptValidator_Validate` and `CBaseEngine_LoadScripts` hooks
are what stop the game rejecting modified scripts, so REDscript mods depend on
RED4ext being injected even though RED4ext's own hooking is broken. Removing it
would silently kill every `.reds` mod.

### Quit crash (fixed)

Every quit used to end in `SIGSEGV`. Cause: the failed `DetourAttach` calls leave
null entries in RED4ext's `DetourTransaction`, and at process exit
`RED4extShutdown()` → `App::Destruct()` walks them and dereferences null at
`0x38`. It fired after the game had fully shut down, so it never risked saves —
but it produced a crash report every session.

Fixed by a Frida guard that replaces `App::Destruct` with a no-op, in
`gamefiles/red4ext/red4ext_hooks.js`. Verified: exit code 0, no crash report,
RED4ext log still completes.

The repository copies of the RED4ext hook and configuration under `gamefiles/`
are authoritative. `sync_gamefiles.sh` restores them after a reinstall and warns
before launch if the live copies drift. Personal REDscript mods remain local and
are never synchronized into this public repository.

## Patcher parity

The patcher used to take the **stock** record as the base for a replacement and
overwrite only `segmentsStart`, `segmentsEnd` and the SHA-1, so every other field
still described the stock resource while the payload was the mod's. It also
applied mods one at a time, which made the last mod to touch a hash win and left
every official archive but the lexicographically first owner unpatched.

That is fixed. A `PatchPlan` is now computed before anything is written and is
consumed by both `patch` and `verify`; the source record is transplanted whole,
with only the two range pairs recomputed, because those index per-archive tables
and mean nothing outside their own archive.

Measured over the 33 enabled mods, before → after:

| Defect | Was | Now |
|---|---|---|
| Records carrying a stale stock timestamp | 20,298 | 0 |
| Records with the stock inline-buffer count | 336 | 0 |
| Stale stock dependency lists kept | 220 | 0 |
| Mod dependency lists dropped | 23 | 0 |
| Official owners of a duplicated hash left unpatched | 75 | 0 |
| Conflicts resolved last-wins instead of Windows first-wins | 3 | 0 |
| Backup directories per run | 678 | 47 (one per rewritten archive) |

A full injection now plans 20,295 override records across 47 archives, writes
20,370 (the extra 75 being duplicate-owner copies), reports the 3 conflicts it
resolved, and `verify --mods` reports every record as matching the plan.

### Remaining defects

`basegame_99_*` loose archives are whole-mod copies, so they carry override
records that can never be read. Roughly 36% of records across the loose archives
are the only ones doing anything. This wastes space but is not incorrect.

## Roadmap

1. **Consolidate loose archives.** Emit one deterministic archive containing only
   genuinely new resources, instead of a whole-mod copy per contributing mod.
2. **Transactional backups.** One manifest per run rather than per archive, with
   pruning.

Not planned: reviving RED4ext native hooking would need a real address database
built for the macOS 2.3.1 binary. That is the only route to ArchiveXL, TweakXL,
and CET, and it is a substantial reverse-engineering effort with uncertain payoff.

## Layout

```
.
├── cp2077-patcher          # arm64 patcher binary (build artifact of patcher/)
├── patcher/                # Swift package — patcher source and tests
├── launch_modded.sh        # full modded launch sequence
├── inject_archives.sh      # inject archive mods
├── restore_archives.sh     # restore vanilla archives
├── sync_gamefiles.sh       # synchronize tracked runtime files
├── gamefiles/              # RED4ext hook, configuration, and signing files
├── enabled/                # your .archive mods (contents ignored)
├── pristine/               # vanilla baselines — irreplaceable (contents ignored)
│   ├── content/            #   32 archives
│   └── ep1/                #   25 archives
└── logs/                   # run logs (contents ignored)
```

Do not commit archives or logs.

## Requirements

- macOS on Apple Silicon (arm64)
- APFS (for `cp -c` clonefile)
- Cyberpunk 2077 2.3.1, GOG build
- Swift 6.x and Xcode, only to rebuild the patcher
