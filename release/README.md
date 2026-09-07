# Release assembly

`assemble.sh` builds the distributable zip from `payload/` and `bin/archive-loader`:

    ./release/assemble.sh --version 0.1.0

It refuses when `--version` disagrees with what the binary reports, so a hand-typed
version cannot ship under the wrong name, and when the binary is missing its
`__RESTRICT` segment — without that, an ambient `DYLD_INSERT_LIBRARIES` injects the
wrapper instead of reaching the game.

Only immutable program files go in the zip. Baselines, state, mods, and logs are
created at first run inside the game directory, so extracting an update over an
existing install cannot destroy them.
