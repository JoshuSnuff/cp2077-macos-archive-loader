# archive-loader

`archive-loader` is a native archive-mod loader for Cyberpunk 2077 on macOS and
Apple Silicon. A release contains one binary and a setup script. It wraps the
launcher you already use, patches official Mac archives in place, verifies the
planned changes, and restores the recorded baseline when the launcher exits.

## Why it rewrites official archives

The macOS game has no mod-loading hook that can override resources owned by an
official archive. A loose archive can add resources, but it cannot override an
existing resource regardless of where it sorts:

| Probe filename | Sort position | Override applied? |
|---|---|---|
| `0_probe_sasha.archive` | Before the official archives | No |
| `basegame_99_probe_sasha.archive` | After the official archives | No |

Those two launches established that in-place rewriting is the available
override mechanism. The loader plans all enabled mods first, then rewrites each
affected official archive once.

## Install, launch, and recover

1. Extract the `archive-loader/` folder into the Cyberpunk 2077 directory,
   beside `Cyberpunk2077.app`.
2. Run the setup script from the game directory:

   ```bash
   ./archive-loader/setup.command
   ```

   Setup clears macOS quarantine when needed, handles a sibling folder left by
   Archive Utility, captures a baseline of the official archives, and prints
   the launch command.
3. Put `.archive` mods in `archive-loader/mods/enabled/`.
4. Run your existing launcher through the loader. For example:

   ```bash
   ./archive-loader/bin/archive-loader run -- ./launch_modded.sh
   ```

   Substitute the launcher you already use. The loader does not edit or replace
   it, and the same wrapper works with `launch_red4ext.sh` or a launcher of your
   own.

If the game or Mac crashes while archives are patched, recover with:

```bash
./archive-loader/bin/archive-loader restore
```

Check the installation without taking the mutation lock:

```bash
./archive-loader/bin/archive-loader status
```

## What the baseline proves

Before capture, setup asks you to run your storefront's verify/repair and
refuses when it finds loader artifacts. The baseline records the captured
archives, their sizes, and SHA-256 hashes so the loader can restore that exact
generation and report later drift.

It does not verify the archives against CDPR's originals. The official archive
set differs by language packs and installed expansions, so that comparison
cannot be complete for every installation. The negative-evidence gate instead
establishes that nothing on this machine had patched the archives at capture
time, and the recorded generation preserves what was captured.

## Disk space

Setup clones every official archive, which on a full install is around 83 GB of
files. It does not need 83 GB of free space: APFS clones share their blocks with
the originals, so capture costs effectively nothing. Measured on a 13 GB
archive, a clone consumed 0 MiB.

Space is used while a session is running, as patched archives diverge from the
clones they share blocks with, and it is released when the baseline is restored.
Measured with 33 mods across 47 archives, that peak was about 5 GiB.

`du` reports the baseline as 83 G because it sums each file's allocated blocks
and cannot see the sharing between them.

## Scope

- Apple Silicon macOS only.
- PC `.archive` mods only.
- RED4ext, Frida, `scc`, and inputloader are neither installed nor managed by
  this release. The loader composes with an existing setup for those tools by
  wrapping its launcher.
- The release does not ship third-party runtime files or anything under
  `gamefiles/`.

## Building from source

Build and test the Swift package with:

```bash
swift build -c release --package-path patcher
cp patcher/.build/release/archive-loader bin/archive-loader
swift test --package-path patcher
```

The shell tests are separate from `swift test`:

```bash
for t in \
    restrict_section setup_command rebaseline dyld_passthrough run_lifecycle \
    restore_command status_command setup_script release_assemble; do
    bash "tests/${t}_test.sh"
done
```

To assemble the versioned Apple Silicon release archive:

```bash
./release/assemble.sh --version 0.1.0
```

It writes `build/archive-loader-0.1.0-macos-arm64.zip` after checking that the
binary reports the requested version and contains the `__RESTRICT` linker
segment. The zip contains immutable program files only; baselines, state, mods,
and logs are created or retained in the game installation.
