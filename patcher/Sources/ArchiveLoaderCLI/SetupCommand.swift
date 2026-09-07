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
        let debug = args.contains("--debug")
            || ProcessInfo.processInfo.environment["ARCHIVE_LOADER_DEBUG"] == "1"

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
        let log = try SessionLog(command: "setup", logsDirectory: game.logsDirectory, debug: debug)

        try reportingErrors(to: log) {
            try runResolved(
                game: game,
                store: store,
                candidate: candidate,
                assumeClean: assumeClean,
                rebaseline: rebaseline,
                log: log
            )
        }
    }

    private static func runResolved(
        game: GameInstall,
        store: BaselineStore,
        candidate: GameCandidate,
        assumeClean: Bool,
        rebaseline: Bool,
        log: SessionLog
    ) throws {

        // Refused before the lock so a live session gets the clearer message.
        try GameRunningGuard.refuseIfRunning(game: game, consequence: setupConsequence)

        // Taken before anything is inspected: a concurrent run must not be
        // able to patch the archives between the gate and the capture.
        let lock = try InstallationLock.acquire(game: game)
        defer { lock.release() }

        // The game can start while the lock is being acquired.
        try GameRunningGuard.refuseIfRunning(game: game, consequence: setupConsequence)

        log.info("Game     \(game.root.path)")
        log.info("Version  \(candidate.version)  (\(candidate.sources.joined(separator: "+")))")
        log.info()

        try runPreflight(game: game, log: log)

        if rebaseline {
            try Rebaseline.run(
                game: game,
                store: store,
                candidate: candidate,
                assumeClean: assumeClean,
                log: log
            )
        } else if let existing = try store.publishedManifest() {
            log.info("Baseline \(existing.archives.count) archives, captured \(existing.capturedAt)")
            log.info("         already published; use --rebaseline to replace it")
        } else {
            try capture(
                game: game,
                store: store,
                candidate: candidate,
                assumeClean: assumeClean,
                log: log
            )
        }

        printLaunchCommand(game: game, log: log)
    }

    /// A capture clones the archives a live session is reading, and a
    /// same-version `--rebaseline` restores them underneath it first.
    static let setupConsequence =
        "capturing a baseline reads the official archives, and --rebaseline restores them,"
        + " neither of which is safe underneath a live session"

    static func runPreflight(game: GameInstall, log: SessionLog) throws {
        let report = Preflight.run(game: game)
        for check in report.checks {
            let detail = check.detail.map { " — \($0)" } ?? ""
            log.detail("\(check.passed ? "OK  " : "FAIL") \(check.description)\(detail)")
        }
        log.info()
        guard report.isClean else {
            throw CLIError.usage("preflight failed; nothing was changed")
        }
    }

    static func capture(
        game: GameInstall,
        store: BaselineStore,
        candidate: GameCandidate,
        assumeClean: Bool,
        log: SessionLog
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

        guard assumeClean || confirmStorefrontVerify(log: log) else {
            throw CLIError.usage("setup needs that confirmation to continue; nothing was changed")
        }

        log.step("Cloning official archives...")
        var count = 0
        let manifest = try store.capture(
            gameVersion: candidate.version,
            storefront: candidate.sources.joined(separator: "+"),
            willClone: { _ in count += 1 }
        )
        try store.publish(manifest)
        log.info("Baseline \(manifest.archives.count) archives captured and published (\(count) cloned)")
        log.info()
    }

    /// The gate detects loader traces, not arbitrary tampering, so the user
    /// attesting to a storefront verify is part of what the baseline's
    /// trustworthiness rests on.
    static func confirmStorefrontVerify(log: SessionLog) -> Bool {
        guard isatty(STDIN_FILENO) == 1 else {
            log.info("""
            This baseline becomes the only copy of your vanilla archives, so it must be
            captured from an unmodified installation. Run your storefront's verify or
            repair first (Steam: Verify integrity; GOG/Heroic: Verify and repair).

            Re-run interactively to confirm, or pass --assume-clean if you have already
            done it.
            """)
            return false
        }

        log.info("""
        This baseline becomes the only copy of your vanilla archives.
        Have you run your storefront's verify/repair on this installation?
        """)
        log.prompt("Continue? [y/N] ")
        guard let answer = readLine(strippingNewline: true)?.lowercased() else { return false }
        return answer == "y" || answer == "yes"
    }

    static func printLaunchCommand(game: GameInstall, log: SessionLog) {
        let launchers = (try? LauncherDetection.detect(game: game)) ?? []
        log.info("Launch your game with:")
        log.info()
        if let launcher = launchers.first {
            log.detail("cd \(shellQuote(game.root.path))")
            log.detail(LauncherDetection.runCommand(for: launcher.url, game: game))
            if launchers.count > 1 {
                log.info()
                log.info("Other launchers found here:")
                for other in launchers.dropFirst() {
                    log.detail(LauncherDetection.runCommand(for: other.url, game: game))
                }
            }
        } else {
            // No launcher is the normal case for someone running archive mods
            // only, which is everything 0.1 supports. Telling them to supply a
            // launcher they have no reason to own would be a dead end, so point
            // run at the game itself — it wraps any executable, not just a
            // script.
            log.detail("cd \(shellQuote(game.root.path))")
            log.detail(LauncherDetection.runCommand(for: GameProcess.executable(in: game), game: game))
            log.info()
            log.info("No launcher script was found here, so that runs the game directly.")
            log.info("If you later add one — for REDscript or RED4ext — wrap it instead:")
            log.info()
            log.detail("./archive-loader/bin/archive-loader run -- ./your_launcher.sh")
            log.info()
            log.info("archive-loader never edits or replaces a launcher; it only wraps one.")
        }
        printLauncherIntegration(game: game, log: log)
        log.info()
    }

    /// Most people start the game from their storefront, not a terminal.
    ///
    /// Both Heroic and Steam accept a wrapper command, and `run -- <cmd>` is
    /// already that shape, so this needs configuring rather than building.
    /// Without it the Play button silently launches unmodded: archives are only
    /// patched for the duration of a `run`.
    static func printLauncherIntegration(game: GameInstall, log: SessionLog) {
        let binary = game.loaderDirectory.appending(path: "bin/archive-loader").path
        log.info()
        log.info("To keep using your storefront's Play button, add a wrapper there:")
        log.info()
        log.detail("Heroic  Settings > Advanced > Wrapper")
        log.info("            Command:   \(binary)")
        log.info("            Arguments: run --")
        log.info()
        log.detail("Steam   Properties > Launch Options")
        log.info("            \(shellQuote(binary)) run -- %command%")
        log.info()
        log.info("Without it, Play launches unmodded — archives are only patched")
        log.info("for the duration of a run.")
    }

    static func shellQuote(_ value: String) -> String {
        guard value.contains(where: { $0 == " " || $0 == "'" }) else { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
