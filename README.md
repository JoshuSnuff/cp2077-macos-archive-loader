# cp2077-macos-archiveloader

Archive mod loader for Cyberpunk 2077 on macOS (Apple Silicon).

Cyberpunk 2077 has no mod-loading hook on macOS. This repo works around that with
four Bash scripts and a prebuilt Swift binary that rewrites the game's own
archives before launch and puts the originals back afterwards.

> Tested against the GOG build, game version 2.3.1, on Apple Silicon. Other
> storefronts may work if the layout under `archive/Mac/` matches.

## Status

Last verified 2026-09-05 against game 2.3.1 with 33 mods enabled.

| Capability | State |
|---|---|
| `.archive` mods that add new resources | Working |
| `.archive` mods that override stock resources | Working, with known metadata defects (below) |
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

`cp2077-patcher` is an arm64 Mach-O built from a separate Swift package,
`CP2077ArchiveCore`, kept as a sibling directory of this repo:

```
Games/Heroic/
├── CP2077 Archive Runtime/     # this repo
├── CP2077 Archive Patcher/     # Swift package — patcher source
└── Cyberpunk 2077/             # game install
```

```bash
cd "../CP2077 Archive Patcher" && swift build -c release
cp .build/release/cp2077-patcher "../CP2077 Archive Runtime/"
```

> The committed binary is currently an unoptimized **debug** build. Rebuild with
> `-c release` when next touched.

CLI, invoked by `inject_archives.sh` but useful directly when debugging one mod:

```bash
./cp2077-patcher scan MOD.archive [...]
./cp2077-patcher detect
./cp2077-patcher verify --game "$CP2077_GAME_DIR"
./cp2077-patcher patch --game "$CP2077_GAME_DIR" [--strategy hybrid|aggressive] [--target T.archive] --mods MOD.archive [...]
./cp2077-patcher restore --game "$CP2077_GAME_DIR" [--backup BACKUP_DIR | --latest]
```

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

## Known defects

Found by audit and independently verified against the 33 enabled mods. All are
latent — no in-game symptom has been observed.

| Defect | Scale |
|---|---|
| Replaced records keep the **stock** record's metadata while carrying the mod's payload | 20,298 override records |
| — differing inline-buffer counts | 336 |
| — mod dependencies dropped / stale stock dependencies kept | 23 / 220 |
| — stale timestamps | 20,298 |
| Conflict priority reversed: last mod patched wins, Windows is first-wins | currently 2 overlaps, identical SHA-1, so no active effect |
| Only the lexicographically first official owner of a duplicated hash is patched | 75 records live in more than one stock archive |
| `verify` checks only index CRC and alignment — cannot detect any of the above | — |

Also: `basegame_99_*` loose archives are whole-mod copies, so they carry override
records that can never be read. Roughly 36% of records across the loose archives
are the only ones doing anything.

## Roadmap

1. **Patcher parity.** Transplant the source record whole instead of copying
   named fields onto the stock record, resolve conflict winners globally with
   Windows first-wins semantics, patch every official owner of a duplicated hash,
   and extend `verify` to compare each output record against what was intended.
2. **Consolidate loose archives.** Emit one deterministic archive containing only
   genuinely new resources, instead of a whole-mod copy per contributing mod.
   Depends on 1.

Not planned: reviving RED4ext native hooking would need a real address database
built for the macOS 2.3.1 binary. That is the only route to ArchiveXL, TweakXL,
and CET, and it is a substantial reverse-engineering effort with uncertain payoff.

## Layout

```
.
├── cp2077-patcher          # arm64 patcher binary (build artifact)
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
