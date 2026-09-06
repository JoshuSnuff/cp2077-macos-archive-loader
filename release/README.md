# Release payload staging

This directory defines the on-disk shape assembled into an `archive-loader`
release. It is not an installed runtime and contains no mutable game data.

The release build copies `bin/patcher` into
`payload/archive-loader/bin/`, the runtime scripts into
`payload/archive-loader/scripts/`, and managed runtime files into
`payload/archive-loader/gamefiles/`. Supported-build manifests will live under
`payload/archive-loader/manifests/` once baseline validation is implemented.

`install.sh --dry-run` can run from either the repository root or an assembled
release. Mutation-capable installation is intentionally not implemented yet.

Assemble the current preflight-only artifact with:

```bash
./release/assemble.sh --version VERSION
```

The result is written beneath the ignored `build/` directory. Assembly does not
copy anything into a game installation.
