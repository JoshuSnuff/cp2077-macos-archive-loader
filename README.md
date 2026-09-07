# Archive-Loader

Archive mod loading for Cyberpunk 2077 on macOS (Apple Silicon).

The Mac version of the game has no way to load `.archive` mods. `archive-loader`
gives it one: it patches your official game archives just before launch, runs
the game, and puts the originals back when you quit. Nothing stays modified
after a session.

- Version 0.1.1
- Apple Silicon Macs only
- PC `.archive` mods only

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
