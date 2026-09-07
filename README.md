# Archive-Loader

Archive mod loading for Cyberpunk 2077 on macOS (Apple Silicon).

The Mac version of the game has no way to load `.archive` mods. `archive-loader`
gives it one: it patches your official game archives just before launch, runs
the game, and puts the originals back when you quit. Nothing stays modified
after a session.

- Version 0.1.0
- Apple Silicon Macs only
- PC `.archive` mods only

## Install

1. Extract the `archive-loader` folder into your Cyberpunk 2077 directory,
   next to `Cyberpunk2077.app`.
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

## Add mods

Drop `.archive` files into:

```
archive-loader/mods/enabled/
```

Remove a file to disable that mod. Mods are applied in alphabetical order, and
when two mods change the same thing the first one wins — the other is reported
at launch, not silently applied.

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

To keep using the Play button in your storefront, add the wrapper there:

| Launcher | Where | What to enter |
|---|---|---|
| Heroic | Settings → Advanced → Wrapper | Command: `.../archive-loader/bin/archive-loader`, Arguments: `run --` |
| Steam | Properties → Launch Options | `"/path/to/archive-loader/bin/archive-loader" run -- %command%` |

Without a wrapper, the Play button launches unmodded: archives are only patched
for the duration of a run.

## If something goes wrong

If the game or your Mac crashes mid-session, the archives are left patched.
Put them back with:

```bash
./archive-loader/bin/archive-loader restore
```

To check the state of your install at any time:

```bash
./archive-loader/bin/archive-loader status
```

If a mod is broken and patching fails, the launch is aborted and your install
is left clean. Add `--vanilla-on-error` to the `run` command if you would
rather have it launch unmodded than not launch at all.

## Disk space

Setup copies every official archive — around 83 GB on a full install — but it
does not need 83 GB of free space. macOS shares the storage between a copy and
its original, so the baseline costs almost nothing. Finder and `du` still count
it as the full size.

Real space is used only while a modded session is running, as the patched
archives diverge from the baseline, and it is released when the game exits.
With 33 mods across 47 archives that peak was about 5 GB.

## What it does not do

- It does not install or manage RED4ext, Frida, `scc`, or the input loader. It
  runs alongside them if you already have them.
- It does not support Intel Macs.
- It does not load anything other than `.archive` mods.

## A note on the baseline

The baseline is a copy of the archives *as they are on your machine* at setup
time. It is what restore puts back, and its hashes let `status` spot later
drift. It is not a verification against CDPR's originals — the official archive
set differs between installs depending on language packs and expansions — which
is why setup asks you to verify through your storefront first and refuses to
capture a baseline that looks already modified.
