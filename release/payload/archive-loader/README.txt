archive-loader — archive mod loading for Cyberpunk 2077 on macOS (Apple Silicon)

INSTALL
  1. Extract this folder into your Cyberpunk 2077 directory, beside
     Cyberpunk2077.app.
  2. Run:  ./archive-loader/setup.command
     It captures a baseline copy of your official archives and prints the
     command to launch with.
  3. Put .archive mods in archive-loader/mods/enabled/

LAUNCH
  Run whatever you already use to start the game, through archive-loader:

      ./archive-loader/bin/archive-loader run -- ./launch_modded.sh

  archive-loader wraps your launcher. It does not edit or replace it, and
  it works the same with launch_red4ext.sh or any script of your own.

RECOVER
  If the game or your Mac crashes mid-session, the official archives are left
  patched. Put them back with:

      ./archive-loader/bin/archive-loader restore

  Check at any time with:

      ./archive-loader/bin/archive-loader status

  Each run, setup, and restore records a session under archive-loader/logs/.
  archive-loader/logs/latest.log points to the most recent session.

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
  Apple Silicon only. Archive mods only — this does not install or manage
  RED4ext, Frida, scc, or inputloader, though it works alongside them if you
  already have them.
