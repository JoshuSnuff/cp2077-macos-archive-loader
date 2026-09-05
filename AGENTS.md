# Repository Guidelines

## Project Structure & Module Organization

This repository is a macOS/Apple Silicon archive mod loader for Cyberpunk 2077. The root scripts are the source:

- `launch_modded.sh` orchestrates injection, REDscript compilation, game launch, and cleanup.
- `inject_archives.sh` restores a clean baseline, stages enabled mods, patches archives, and verifies them.
- `restore_archives.sh` restores vanilla archives and removes generated artifacts.
- `cp2077-patcher` is a prebuilt arm64 Mach-O binary; its Swift source is not in this repository.
- `enabled/` holds local `.archive` mods, `pristine/{content,ep1}/` holds clean baselines, and `logs/` holds run logs. Their contents are intentionally ignored.
- `docs/superpowers/specs/` contains design notes.

## Build, Test, and Development Commands

There is no build step or dependency installation. Export the game path before running integration commands:

```bash
export CP2077_GAME_DIR="/path/to/Cyberpunk 2077"
bash -n launch_modded.sh inject_archives.sh restore_archives.sh
./inject_archives.sh
./cp2077-patcher verify --game "$CP2077_GAME_DIR"
./restore_archives.sh
./launch_modded.sh
```

`bash -n` performs a safe syntax check. Injection and launch modify the game installation temporarily; always finish testing with restoration.

## Coding Style & Naming Conventions

Use Bash with `set -euo pipefail`, four-space indentation, `UPPER_SNAKE_CASE` for path constants, and `lower_snake_case` for functions and locals. Quote every path and array expansion because game and mod names may contain spaces. Preserve NUL-delimited `find ... -print0 | sort -z` processing. Route operational messages through `log()` when a script has logging. Keep the injection and standalone restoration cleanup paths synchronized, while retaining their documented backup-handling difference.

## Testing Guidelines

No automated test framework or coverage target exists. At minimum, run `bash -n` on every script changed. For behavioral changes, test no-mod, successful injection, patch failure, normal game exit, non-zero exit, and interrupt cleanup as applicable. Confirm the final `verify` succeeds and the game is returned to pristine state. Never test without a populated, trusted `pristine/` baseline.

## Commit & Pull Request Guidelines

Recent commits use short, imperative subjects such as `Add launch_modded.sh...`, `Make game directory configurable...`, and `Track directory structure...`. Follow that style and keep each commit focused. Pull requests should explain user-visible behavior, recovery implications, test commands and results, and linked issues. Include relevant log excerpts for runtime changes; screenshots are only useful for visible game-launch behavior. Never commit game archives, pristine data, or logs.
