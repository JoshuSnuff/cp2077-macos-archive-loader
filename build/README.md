# Building archive-loader yourself

Nothing here needs a prebuilt binary. The release zip is assembled from this
repository by two commands, and the result is the same program described in the
[README](../README.md).

## Requirements

- An Apple Silicon Mac running macOS 14 or later
- Xcode or the Command Line Tools, providing Swift 6.3 or newer
  (`swift --version`)

No game installation is needed to build or to run the test suite.

## Build

```bash
swift build -c release --package-path patcher
cp patcher/.build/release/archive-loader bin/archive-loader
```

`bin/archive-loader` is now a complete loader. You can run it in place with
`--game "/path/to/Cyberpunk 2077"`, which is how development is done, or package
it for installation with the step below.

## Test

```bash
swift test --package-path patcher
```

The shell tests cover the CLI, the launch path, and the shape of the release,
and are not run by `swift test`:

```bash
for t in \
    restrict_section setup_command rebaseline dyld_passthrough run_lifecycle \
    restore_command status_command patch_command setup_script release_assemble \
    logging; do
    bash "tests/${t}_test.sh"
done
```

## Package

```bash
./release/assemble.sh --version 0.1.0
```

This writes `build/archive-loader-0.1.0-macos-arm64.zip`. The version is the one
the binary reports (`./bin/archive-loader --version`), and `assemble.sh` refuses
to package under any other name, so a zip cannot be labelled as a build it does
not contain. It also refuses a binary missing its `__RESTRICT` segment — without
that segment, a `DYLD_INSERT_LIBRARIES` exported from your shell profile injects
into the loader instead of reaching the game.

Only program files go into the zip. Baselines, mods, state, and logs live in the
game directory and are created on first use, so extracting a new build over an
existing install leaves them intact.

## Install what you built

Extract the zip's `archive-loader` folder into your Cyberpunk 2077 directory,
next to `Cyberpunk2077.app`, then continue from step 2 of
[Install](../README.md#install).
