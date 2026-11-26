archive-loader — archive mod loading for Cyberpunk 2077 on macOS (Apple Silicon)

INSTALL
  1. Extract this folder into your Cyberpunk 2077 directory, beside
     Cyberpunk2077.app.
  2. Run:  ./archive-loader/setup.command
     It captures a baseline copy of your official archives and prints the
     command to launch with.
  3. Put .archive mods in archive-loader/mods/enabled/. TweakDB mods go in
     archive-loader/mods/tweaks/.

OPTIONAL NATIVE TWEAKXL/ARCHIVEXL RUNTIME
  The loader does not download third-party runtimes. Prepare a directory that
  extends the compatibility package for the exact supported game build:

      runtime-package/archive-loader/compatibility/manifest.json
      runtime-package/archive-loader/red4ext/RED4ext.dylib
      runtime-package/archive-loader/red4ext/plugins/TweakXL.dylib
      runtime-package/archive-loader/red4ext/plugins/ArchiveXL.dylib

  The manifest uses cp2077-compatibility/v1, pins the game, distribution,
  platform, arm64 architecture, version, bundle version, GOG build ID, and
  executable UUID/hash, and lists every package file in its self-hashed
  managedFiles inventory. Its frameworkRuntime section must declare:

      schema: archive-loader-framework-runtime/v1
      roles: red4ext-loader, tweakxl-plugin, archivexl-plugin
      DYLD_INSERT_LIBRARIES: prepend red4ext/RED4ext.dylib
      DYLD_FORCE_FLAT_NAMESPACE: replace with 1

  Every required dylib must be an executable arm64 Mach-O, pass
  codesign --verify --deep --strict, have a lowercase SHA-256 in the manifest,
  and have no quarantine attribute. Do not copy these files into the game by
  hand or rely on an implicit ad-hoc resign.

  Install the package during first setup with:

      ./archive-loader/bin/archive-loader setup \
        --runtime-package "/path/to/runtime-package" \
        --game "/path/to/Cyberpunk 2077" --assume-clean

  A requested package is validated before setup writes a baseline or installs
  anything, and it never silently falls back to offline behavior. Re-running
  setup with --runtime-package upgrades the permanent runtime without replacing
  an existing baseline; add --rebaseline only after verifying the official game
  files again.

LAUNCH
  Run whatever you already use to start the game, through archive-loader:

      ./archive-loader/bin/archive-loader run -- ./launch_modded.sh

  archive-loader wraps your launcher. It does not edit or replace it, and
  it works the same with launch_red4ext.sh or any script of your own.

  An unchanged set of mods, game files, official archives, and baseline can
  reuse the previous run's cached patched image instead of rewriting archives.
  A cache hit still builds the full patch plan and runs the same verification as
  a fresh patch; use --no-cache to force a full patch or use `cache clear` to
  discard cached images. Two cache generations are retained, and the
  fingerprint can miss only an in-place mod rewrite that preserves its size,
  mtime, and inode.

RECOVER
  If the game or your Mac crashes mid-session, the official archives are left
  patched. Put them back with:

      ./archive-loader/bin/archive-loader restore

  Check at any time with:

      ./archive-loader/bin/archive-loader status

  Each run, setup, and restore records a session under archive-loader/logs/.
  archive-loader/logs/latest.log points to the most recent session.

TWEAKDB
  The offline builder supports assignments to existing flats and array append/
  remove operations in .yaml, .yml, and .tweak files. Use:

      ./archive-loader/bin/archive-loader tweaks build --game "/path/to/Cyberpunk 2077"

  Select `base` or `ep1` explicitly when needed. Exact root-level `requires` or
  `dependencies` entries containing TweakXL or ArchiveXL select native runtime
  handling instead. Those .yaml/.yml/.tweak documents are projected during the
  session into r6/tweaks/ for TweakXL. ArchiveXL .xl payloads, and .archive
  payloads with an exact ArchiveXL sidecar declaration, are projected into
  archive/Mac/mod/. Runtime-owned documents are not sent through the offline
  builder; documents without an exact marker keep their offline behavior.
  Use --no-tweaks to skip only the offline TweakDB build.

STATE AND RUNTIME REMOVAL
  The verified compatibility package is permanent state: its RED4ext, TweakXL,
  and ArchiveXL files remain installed across run and restore, under one
  transaction recorded in archive-loader/state/. Archives, offline TweakDB
  blobs, and native framework projections are session state. restore removes
  session changes and keeps the runtime; status reports the two states
  independently.

  To remove only the permanent runtime, while the game is stopped, run:

      ./archive-loader/bin/archive-loader runtime remove \
        --game "/path/to/Cyberpunk 2077"

  This restores the compatibility transaction snapshot, removes only files it
  owns, preserves unrelated red4ext files, and leaves archives/TweakDB alone.

WHAT THE BASELINE IS
  setup clones your official archives into archive-loader/baselines/ and
  records their sizes and SHA-256 hashes. Restoring means cloning those back.
  It does NOT verify them against CDPR's originals — the official archive set
  differs per user, depending on language packs and whether Phantom Liberty is
  installed, so that cannot be done completely. What it does establish is that
  nothing had patched them at capture time, and it refuses to capture if it
  finds any sign that something had.

  Run your storefront's verify/repair before setup.

SCOPE
  Apple Silicon only. Archive mods, offline existing-flat TweakDB edits, and
  verified native TweakXL/ArchiveXL packages. The loader does not download or
  build third-party frameworks, and it does not manage unrelated Frida, scc,
  or inputloader installations.
