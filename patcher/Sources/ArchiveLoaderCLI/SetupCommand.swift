import CP2077ArchiveCore
import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum SetupCommand {
    static func run(_ args: [String]) throws {
        let options = try Options(args)
        let assumeClean = args.contains("--assume-clean")
        let rebaseline = args.contains("--rebaseline")

        let explicitRoot = options.value("--game").map { URL(fileURLWithPath: $0, isDirectory: true) }
        let candidates = try GameDiscovery.resolve(explicitRoot: explicitRoot)
        guard let candidate = candidates.first else {
            throw CLIError.usage("could not find Cyberpunk 2077. Pass --game explicitly.")
        }
        if candidates.count > 1 {
            let paths = candidates.map { "  \($0.root.path)" }.joined(separator: "\n")
            throw CLIError.usage("multiple installations found; pass --game explicitly:\n\(paths)")
        }

        let game = GameInstall(root: candidate.root)
        let store = BaselineStore(game: game)

        // Taken before anything is inspected: a concurrent run must not be
        // able to patch the archives between the gate and the capture.
        let lock = try InstallationLock.acquire(game: game)
        defer { lock.release() }

        print("Game     \(game.root.path)")
        print("Version  \(candidate.version)  (\(candidate.sources.joined(separator: "+")))")
        print("")

        try runPreflight(game: game)

        if rebaseline {
            try Rebaseline.run(game: game, store: store, candidate: candidate, assumeClean: assumeClean)
        } else if let existing = try store.publishedManifest() {
            print("Baseline \(existing.archives.count) archives, captured \(existing.capturedAt)")
            print("         already published; use --rebaseline to replace it")
        } else {
            try capture(game: game, store: store, candidate: candidate, assumeClean: assumeClean)
        }

        printLaunchCommand(game: game)
    }

    static func runPreflight(game: GameInstall) throws {
        let report = Preflight.run(game: game)
        for check in report.checks {
            let detail = check.detail.map { " — \($0)" } ?? ""
            print("  \(check.passed ? "OK  " : "FAIL") \(check.description)\(detail)")
        }
        print("")
        guard report.isClean else {
            throw CLIError.usage("preflight failed; nothing was changed")
        }
    }

    static func capture(
        game: GameInstall,
        store: BaselineStore,
        candidate: GameCandidate,
        assumeClean: Bool
    ) throws {
        let evidence = try NegativeEvidence.inspect(game: game)
        guard evidence.isClean else {
            throw CLIError.usage(
                "this installation shows signs of having been patched already, so a baseline"
                    + " captured from it would record the damage as vanilla:\n"
                    + evidence.summary
                    + "\n\nNothing was changed."
            )
        }

        guard assumeClean || confirmStorefrontVerify() else {
            throw CLIError.usage("setup needs that confirmation to continue; nothing was changed")
        }

        print("Cloning official archives...")
        var count = 0
        let manifest = try store.capture(
            gameVersion: candidate.version,
            storefront: candidate.sources.joined(separator: "+"),
            willClone: { _ in count += 1 }
        )
        try store.publish(manifest)
        print("Baseline \(manifest.archives.count) archives captured and published (\(count) cloned)")
        print("")
    }

    /// The gate detects loader traces, not arbitrary tampering, so the user
    /// attesting to a storefront verify is part of what the baseline's
    /// trustworthiness rests on.
    static func confirmStorefrontVerify() -> Bool {
        guard isatty(STDIN_FILENO) == 1 else {
            print("""
            This baseline becomes the only copy of your vanilla archives, so it must be
            captured from an unmodified installation. Run your storefront's verify or
            repair first (Steam: Verify integrity; GOG/Heroic: Verify and repair).

            Re-run interactively to confirm, or pass --assume-clean if you have already
            done it.
            """)
            return false
        }

        print("""
        This baseline becomes the only copy of your vanilla archives.
        Have you run your storefront's verify/repair on this installation?
        """)
        print("Continue? [y/N] ", terminator: "")
        guard let answer = readLine(strippingNewline: true)?.lowercased() else { return false }
        return answer == "y" || answer == "yes"
    }

    static func printLaunchCommand(game: GameInstall) {
        let launchers = (try? LauncherDetection.detect(game: game)) ?? []
        print("Launch your game with:")
        print("")
        if let launcher = launchers.first {
            print("  cd \(shellQuote(game.root.path))")
            print("  \(LauncherDetection.runCommand(for: launcher.url, game: game))")
            if launchers.count > 1 {
                print("")
                print("Other launchers found here:")
                for other in launchers.dropFirst() {
                    print("  \(LauncherDetection.runCommand(for: other.url, game: game))")
                }
            }
        } else {
            // No launcher is the normal case for someone running archive mods
            // only, which is everything 0.1 supports. Telling them to supply a
            // launcher they have no reason to own would be a dead end, so point
            // run at the game itself — it wraps any executable, not just a
            // script.
            print("  cd \(shellQuote(game.root.path))")
            print("  \(LauncherDetection.runCommand(for: GameProcess.executable(in: game), game: game))")
            print("")
            print("No launcher script was found here, so that runs the game directly.")
            print("If you later add one — for REDscript or RED4ext — wrap it instead:")
            print("")
            print("  ./archive-loader/bin/archive-loader run -- ./your_launcher.sh")
            print("")
            print("archive-loader never edits or replaces a launcher; it only wraps one.")
        }
        printLauncherIntegration(game: game)
        print("")
    }

    /// Most people start the game from their storefront, not a terminal.
    ///
    /// Both Heroic and Steam accept a wrapper command, and `run -- <cmd>` is
    /// already that shape, so this needs configuring rather than building.
    /// Without it the Play button silently launches unmodded: archives are only
    /// patched for the duration of a `run`.
    static func printLauncherIntegration(game: GameInstall) {
        let binary = game.loaderDirectory.appending(path: "bin/archive-loader").path
        print("")
        print("To keep using your storefront's Play button, add a wrapper there:")
        print("")
        print("  Heroic  Settings > Advanced > Wrapper")
        print("            Command:   \(binary)")
        print("            Arguments: run --")
        print("")
        print("  Steam   Properties > Launch Options")
        print("            \(shellQuote(binary)) run -- %command%")
        print("")
        print("Without it, Play launches unmodded — archives are only patched")
        print("for the duration of a run.")
    }

    static func shellQuote(_ value: String) -> String {
        guard value.contains(where: { $0 == " " || $0 == "'" }) else { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
