# Release assembly

This directory defines the release zip for `archive-loader` on macOS Apple
Silicon. It is not an installed runtime and contains no mutable game data.

Assemble the release artifact with:

```bash
./release/assemble.sh --version 0.1.0
```

The result is written beneath the ignored `build/` directory as
`archive-loader-0.1.0-macos-arm64.zip`.

Assembly refuses to produce a release when the requested version disagrees
with the version reported by `bin/archive-loader`, or when the binary does not
contain the `__RESTRICT` segment required to keep ambient
`DYLD_INSERT_LIBRARIES` out of the wrapper.

The zip contains only immutable program files:

```text
archive-loader/
├── setup.sh
├── bin/archive-loader
├── mods/enabled/.keep
├── README.txt
└── version
```

Baselines, pristine data, state, mods, and logs are created at first run, so
extracting an update cannot destroy them. The release does not ship
`install.sh`, third-party runtime files, or supported-build manifests.
