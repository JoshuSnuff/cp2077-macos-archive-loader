# Archive-Loader

Archive mod loading for Cyberpunk 2077 on macOS (Apple Silicon).

The Mac version of the game has no way to load `.archive` mods. `archive-loader`
gives it one: it patches your official game archives just before launch, runs
the game, and puts the originals back when you quit. Nothing stays modified
after a session.

- Version 0.1.3
- Apple Silicon Macs only
- PC `.archive` mods, plus optional native framework resources
- Offline TweakDB edits for existing flats and arrays
- Optional native TweakXL and ArchiveXL support through a verified compatibility package

## Install

1. Extract the `archive-loader` folder into your Cyberpunk 2077 directory,
   next to `Cyberpunk2077.app`. If you would rather not run a binary someone
   else built, [build it yourself](build/README.md) first.
2. Before the next step, run your storefront's verify/repair on the game
   (Steam: *Verify integrity of game files*; GOG/Heroic: *Verify and repair*).
   Setup takes a snapshot of your archives and needs them unmodified.
3. Double-click `archive-loader/setup.command`, or run it from the game
   directory:

   ```bash
   ./archive-loader/setup.command
   ```

Setup records a baseline copy of your official archives and prints the exact
command to launch with. It refuses to continue if it finds signs that something
has already modified your archives.

### Optional native TweakXL and ArchiveXL runtime

The loader does not download third-party runtime files. To use real TweakXL or
ArchiveXL mods, prepare a directory that extends the compatibility package for
your exact supported game build:

```
runtime-package/
└── archive-loader/
    ├── compatibility/manifest.json
    └── red4ext/
        ├── RED4ext.dylib
        └── plugins/
            ├── TweakXL.dylib
            └── ArchiveXL.dylib
```

The manifest must use `cp2077-compatibility/v1`, pin the game, distribution,
platform, arm64 architecture, marketing version, bundle version, GOG build ID,
and executable UUID/hash, and list every package file in its self-hashed
`managedFiles` inventory. A native runtime manifest also contains this exact
capability declaration:

```json
{
  "schema": "archive-loader-framework-runtime/v1",
  "roles": ["red4ext-loader", "tweakxl-plugin", "archivexl-plugin"],
  "environment": {
    "DYLD_INSERT_LIBRARIES": {
      "mode": "prepend",
      "paths": ["red4ext/RED4ext.dylib"]
    },
    "DYLD_FORCE_FLAT_NAMESPACE": { "mode": "replace", "value": "1" }
  }
}
```

Every required dylib must be a regular executable arm64 Mach-O file, pass
`codesign --verify --deep --strict`, have a lowercase SHA-256 recorded in the
manifest, and have no quarantine attribute. Do not copy runtime files directly
into the game or rely on an implicit ad-hoc resign. An identity, hash, signing,
architecture, or package-layout failure is reported before setup writes a
baseline or installs anything; a requested runtime never silently falls back to
offline behavior.

On the first setup, install the package and capture the archive/TweakDB
baseline together:

```bash
./archive-loader/bin/archive-loader setup \
  --runtime-package "/path/to/runtime-package" \
  --game "/path/to/Cyberpunk 2077" \
  --assume-clean
```

On an installation that already has a baseline, `setup --runtime-package PATH`
installs or upgrades the permanent runtime without replacing that baseline.
Add `--rebaseline` only when the official game files have been verified again
and the baseline should be replaced.

## Add mods

Drop `.archive` files into:

```
archive-loader/mods/enabled/
```

Remove a file to disable that mod. Mods are applied in alphabetical order, and
when two mods change the same thing the first one wins — the other is reported
at launch, not silently applied.

TweakDB mods (`.yaml`, `.yml`, or `.tweak`) go under
`archive-loader/mods/tweaks/`. The supported offline subset assigns existing
flats and appends/removes array values. Use `base` or `ep1` selectors when an
operation must target one blob, or build and verify offline:

```bash
./archive-loader/bin/archive-loader tweaks build --game "/path/to/Cyberpunk 2077"
```

For native framework mods, the loader recognizes only exact root-level
`requires` or `dependencies` entries containing `TweakXL` or `ArchiveXL`.

- Runtime-owned `.yaml`, `.yml`, and `.tweak` documents are copied for the
  session into the native TweakXL discovery path, `r6/tweaks/`.
- ArchiveXL `.xl` payloads, and `.archive` payloads with an exact ArchiveXL
  sidecar declaration, are copied for the session into `archive/Mac/mod/`.
- Runtime-owned documents are not sent through the offline TweakDB builder.
  Documents without an exact dependency marker keep their offline behavior;
  ordinary `.archive` mods keep the loader's archive-patching behavior.

The projected files use loader-owned names and are removed by `restore` after
the game exits. Do not copy framework mods manually into the native paths.
Native framework mods require an active verified runtime package.

## Launch

Start the game through `archive-loader` instead of directly:

```bash
cd "/path/to/Cyberpunk 2077"
./archive-loader/bin/archive-loader run -- ./launch_modded.sh
```

Replace `./launch_modded.sh` with whatever you normally use. If you have no
launcher script, setup prints a command that runs the game itself.
`archive-loader` wraps your launcher — it never edits or replaces it, so it
works alongside a REDscript or RED4ext setup you already have.

After a successful run, a later run with the same mods, game version, official
archive set, and baseline reuses the cached patched image instead of rewriting
the archives. A cache hit still builds the full patch plan and runs the same
verification as a fresh patch. Add `--no-cache` to force a full patch, or run
`cache clear` to discard cached images; the two most recent images are retained.
The fingerprint can miss only an in-place mod rewrite that preserves its size,
mtime, and inode.

To keep using the Play button in your storefront, add the wrapper there:

| Launcher | Where | What to enter |
|---|---|---|
| Heroic | Settings → Advanced → Wrapper | Command: `.../archive-loader/bin/archive-loader`, Arguments: `run --` |
| Steam | Properties → Launch Options | `"/path/to/archive-loader/bin/archive-loader" run -- %command%` |

Without a wrapper, the Play button launches unmodded: archives are only patched
for the duration of a run.

Use `run --no-tweaks` for archive-only launches.

`--no-tweaks` skips the offline TweakDB build; it does not disable a verified
native runtime or its session projections.

## Permanent and session state

The compatibility package is permanent installation state. Its RED4ext,
TweakXL, and ArchiveXL files are installed under their native game-root paths,
owned by one transactional compatibility record under `archive-loader/state/`,
and remain installed across `run` and `restore`. A later package can upgrade or
downgrade that same transaction safely.

Archives, offline TweakDB blobs, and native framework projections are session
state. `run` restores any previous interrupted session, applies the requested
changes, launches your unchanged command, and removes the projections on exit.
If a crash or SIGKILL leaves session data behind, run `restore` before playing
again. `status` reports the permanent runtime independently from the live
archive/TweakDB state.

Remove only the permanent runtime with:

```bash
./archive-loader/bin/archive-loader runtime remove \
  --game "/path/to/Cyberpunk 2077"
```

The game must not be running. This command restores the transaction snapshot and
removes only files owned by the installed compatibility package; unrelated files
in `red4ext/` are preserved. It does not restore archives, delete TweakDB
changes, or remove a session projection. Use `restore` for session cleanup.

## If something goes wrong

If the game or your Mac crashes mid-session, the archives are left patched.
Put them back with:

```bash
./archive-loader/bin/archive-loader restore
```

`restore` keeps an installed native runtime. To remove that permanent runtime,
use `runtime remove` as described above.

To check the state of your install at any time:

```bash
./archive-loader/bin/archive-loader status
```

If a mod is broken and patching fails, the launch is aborted and your install
is left clean. Add `--vanilla-on-error` to the `run` command if you would
rather have it launch unmodded than not launch at all.

Each `run`, `setup`, and `restore` keeps a session log in
`archive-loader/logs/`. Open `archive-loader/logs/latest.log` to see the most
recent session.

## Disk space

Setup copies every official archive — around 83 GB on a full install — but it
does not need 83 GB of free space. macOS shares the storage between a copy and
its original, so the baseline costs almost nothing. Finder and `du` still count
it as the full size.

Real space is used only while a modded session is running, as the patched
archives diverge from the baseline, and it is released when the game exits.
With 33 mods across 47 archives that peak was about 5 GB.

## Build it yourself

The loader builds from this repository with Swift 6.3 and no game installation:
two commands produce the binary, and a third packages the same zip that is
released. See [build/README.md](build/README.md).
