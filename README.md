# archive-loader

Archive mod loader for Cyberpunk 2077 on macOS and Apple Silicon.

> **Pre-release:** the loader works locally, but the installer is not ready for
> general use. `install.sh` currently provides a read-only preflight only.

## What's this?

Cyberpunk 2077 does not load PC `.archive` mods on macOS. `archive-loader`
temporarily patches the game's official Mac archives before launch, verifies the
result, starts the game, and restores the original archives when the game exits.

The project also runs REDscript compilation and Input Loader when those tools
are installed.

## Compatibility

| Feature | Support |
|---|---|
| `.archive` mods adding new resources | Yes |
| `.archive` mods overriding game resources | Yes |
| REDscript mods | Yes |
| Input Loader | Yes |
| ArchiveXL and `.archive.xl` | No |
| TweakXL, CET, and RED4ext native plugins | No |

Tested with the GOG build, game version 2.3.1, on Apple Silicon. Other
storefronts are detected, but have not received the same runtime testing.

## Usage

After installation, put `.archive` mods in:

```text
<game>/mods/enabled/
```

Then launch through:

```text
<game>/launch_modded.sh
```

The game-root installer is still in development. You can safely inspect what it
would do:

```bash
./install.sh --dry-run
./install.sh --dry-run --game "/path/to/Cyberpunk 2077"
```

The preflight detects Steam, GOG, and Heroic installations, validates the game
layout, and checks Apple Silicon, APFS, and directory permissions. It does not
change any files.

## Development setup

The current source workflow requires a trusted pristine baseline. Do not test
injection without one.

```bash
export ARCHIVE_LOADER_GAME_DIR="$(./bin/archive-loader detect)"
./sync_gamefiles.sh
./launch_modded.sh
```

Place archive mods in `enabled/`. Populate `pristine/content/` and
`pristine/ep1/` from a verified clean installation before the first launch.

The tracked RED4ext hooks and configuration are under `gamefiles/`. Third-party
runtime versions and sources are listed in
[`gamefiles/README.md`](gamefiles/README.md).

## Patcher

`bin/archive-loader` is the bundled arm64 release executable. Its Swift source and
tests are under `patcher/`.

```bash
./bin/archive-loader detect
./bin/archive-loader detect --all --format json
./bin/archive-loader help
```

To rebuild it:

```bash
swift build -c release --package-path patcher
cp patcher/.build/release/archive-loader bin/archive-loader
swift test --package-path patcher
```

## Safety

Patching rewrites official archives temporarily. The launcher restores the
pristine baseline before every injection and again when the game exits. If a
session is killed before cleanup, run `restore_archives.sh`; the next modded
launch also restores first.

Never commit game archives, pristine data, personal mods, or logs.

## Contributing

Run the checks relevant to your change:

```bash
bash -n launch_modded.sh inject_archives.sh restore_archives.sh sync_gamefiles.sh install.sh
swift test --package-path patcher
```

Keep archive cleanup paths synchronized and preserve NUL-delimited, ASCII-sorted
mod discovery.
