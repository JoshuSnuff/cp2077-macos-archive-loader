import CP2077ArchiveCore
import Foundation

/// Exit code for a failed restore.
///
/// Deliberately outside the range a game or launcher would produce, so "your
/// install is still patched" can never be read as the game's own exit status.
private let restoreFailureExitCode: Int32 = 70

enum RunCommand {
    static func run(_ args: [String]) throws {
        var arguments = args
        var vanillaOnError = false
        var explicitGame: String?

        // Everything after `--` belongs to the launcher, untouched.
        var wrapped: [String] = []
        if let separator = arguments.firstIndex(of: "--") {
            wrapped = Array(arguments[(separator + 1)...])
            arguments = Array(arguments[..<separator])
        }

        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--vanilla-on-error":
                vanillaOnError = true
                index += 1
            case "--game":
                guard index + 1 < arguments.count else { throw CLIError.missingValue("--game") }
                explicitGame = arguments[index + 1]
                index += 2
            default:
                throw CLIError.usage("unknown run option: \(arguments[index])")
            }
        }

        guard let launcherPath = wrapped.first else {
            throw CLIError.usage(
                "usage: archive-loader run [--vanilla-on-error] [--game GAME_DIR] -- <launcher> [args...]"
            )
        }
        let launcherArguments = Array(wrapped.dropFirst())

        let candidates = try GameDiscovery.resolve(
            explicitRoot: explicitGame.map { URL(fileURLWithPath: $0, isDirectory: true) }
        )
        guard let candidate = candidates.first, candidates.count == 1 else {
            throw CLIError.usage("could not resolve a single game installation; pass --game")
        }
        let game = GameInstall(root: candidate.root)
        let store = BaselineStore(game: game)
        let ledger = ArtifactLedger(game: game)

        let launcher = resolveLauncher(launcherPath, gameRoot: game.root)

        // Refused before the lock so a live session gets the clearer message.
        guard !GameProcess.isRunning(game: game) else {
            throw CLIError.usage(
                "Cyberpunk 2077 is already running from this installation."
                    + " Quit it first: restoring now would rewrite archives underneath it."
            )
        }

        let lock = try InstallationLock.acquire(game: game)
        defer { lock.release() }

        // The game could have started during lock acquisition. Never restore
        // under a session that won the race after the initial pre-lock check.
        guard !GameProcess.isRunning(game: game) else {
            throw CLIError.usage(
                "Cyberpunk 2077 is already running from this installation."
                    + " Quit it first: restoring now would rewrite archives underneath it."
            )
        }

        guard let manifest = try store.publishedManifest() else {
            throw CLIError.usage(
                "no baseline has been captured for this installation."
                    + " Run: archive-loader setup"
            )
        }
        guard manifest.gameVersion == candidate.version else {
            throw CLIError.usage(
                "the game has been updated since the baseline was captured"
                    + " (\(manifest.gameVersion) -> \(candidate.version))."
                    + " Run: archive-loader setup --rebaseline"
            )
        }

        // 1. Restore first. A prior SIGKILL or power loss leaves the install
        //    patched, and patching again on top would stack a second edit.
        print("Restoring \(manifest.archives.count) archives...")
        do {
            try restore(store: store, ledger: ledger)
        } catch {
            reportRestoreFailure(error, game: game)
            exit(restoreFailureExitCode)
        }

        // 2. Patch, unless there is nothing to patch.
        let mods = try ModCollection.enabledMods(game: game)
        if mods.isEmpty {
            // Not an error: a no-mod run still restores, cleans up, and
            // launches. It is the normal way to play unmodded through the
            // same command, and `patch` rejects an empty --mods list anyway.
            print("No mods in \(game.modsEnabledDirectory.path); launching unmodded")
        } else {
            do {
                try patchAndVerify(mods: mods, game: game, ledger: ledger)
            } catch {
                let patchError = error
                // Patch and verification can fail after writing some files.
                // Recover before surfacing either failure or falling back.
                do {
                    try recordExistingManagedArtifact(game: game, ledger: ledger)
                } catch {
                    reportRestoreFailure(error, game: game)
                    exit(restoreFailureExitCode)
                }
                if let restoreError = restoreQuietly(store: store, ledger: ledger) {
                    reportRestoreFailure(restoreError, game: game)
                    exit(restoreFailureExitCode)
                }

                guard vanillaOnError else {
                    throw CLIError.usage(
                        "\(patchError)\n\nThe launch was aborted and the install left pristine."
                            + " Pass --vanilla-on-error to launch unmodded instead."
                    )
                }
                print("warning: \(patchError)")
                print("warning: --vanilla-on-error given; restoring and launching unmodded")
                do {
                    try restore(store: store, ledger: ledger)
                } catch {
                    reportRestoreFailure(error, game: game)
                    exit(restoreFailureExitCode)
                }
            }
        }

        // 3. Launch, then restore on every path out.
        var outcome: LaunchOutcome

        // Started before the launcher so that a foreground launcher's session
        // is observed while it happens.
        let watcher = GameWatcher(executable: GameProcess.executable(in: game))
        watcher.start()
        defer { watcher.stop() }

        let gameExecutable = GameProcess.executable(in: game)
        let launcherTarget = LockedProcessTarget()
        let signalForwarder = SignalForwarder {
            if let launcherPID = launcherTarget.value {
                return [launcherPID]
            }
            return GameProcess.runningPIDs(matching: gameExecutable)
        }
        signalForwarder.start()
        defer { signalForwarder.stop() }

        do {
            outcome = try LaunchSupervisor.run(
                executable: launcher,
                arguments: launcherArguments,
                workingDirectory: game.root,
                onStarted: { launcherTarget.value = $0 },
                signalForwarder: signalForwarder
            )
        } catch {
            // Even a launcher that never started leaves a patched install.
            launcherTarget.value = nil
            if let restoreError = restoreQuietly(store: store, ledger: ledger) {
                reportRestoreFailure(restoreError, game: game)
                exit(restoreFailureExitCode)
            }
            throw error
        }

        launcherTarget.value = nil
        waitForGameToFinish(game: game, watcher: watcher)
        watcher.stop()
        let restoreError = restoreQuietly(store: store, ledger: ledger)

        let launcherCode = outcome.wasSignalled
            ? outcome.reportableCode
            : signalForwarder.receivedSignal.map { 128 + $0 } ?? outcome.reportableCode
        if let restoreError {
            reportRestoreFailure(restoreError, game: game, launcherCode: launcherCode)
            exit(restoreFailureExitCode)
        }
        if launcherCode != 0 {
            exit(launcherCode)
        }
    }

    /// The launcher is normally given relative to the game directory, which is
    /// also the working directory the child gets.
    static func resolveLauncher(_ path: String, gameRoot: URL) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return gameRoot.appending(path: path).standardizedFileURL
    }

    static func patchAndVerify(mods: [URL], game: GameInstall, ledger: ArtifactLedger) throws {
        print("Patching with \(mods.count) mods...")
        for mod in mods {
            print("  \(mod.lastPathComponent)")
        }

        let plan = try PatchPlanner.plan(mods: mods, game: game)
        for loser in plan.losers {
            print(
                "  conflict: \(Hashes.hex64(loser.hash)) in \(loser.modArchive.lastPathComponent)"
                    + " loses to \(loser.winnerArchive.lastPathComponent)"
            )
        }

        let summary = try RDARPatcher(game: game).apply(plan: plan)
        if let loose = summary.looseArchive {
            try ledger.record([loose])
        }
        print("Patched \(summary.overrideRecordCount) records across \(summary.archives.count) archives")

        // A plan that cannot be verified is not one to play on.
        let report = try PlanVerifier.verify(plan: plan, game: game)
        guard report.isClean else {
            for archive in report.archives where !archive.isClean {
                print("  BAD \(archive.archive.lastPathComponent)")
                for issue in archive.issues {
                    print("      ! \(issue)")
                }
            }
            throw CLIError.usage("verification failed after patching")
        }
        print(
            "Verified \(report.matchingRecordCount) records match the plan"
                + " across \(report.archives.count) archives"
        )
    }

    /// The launcher exiting is not the session ending.
    ///
    /// Both upstream launchers run the game in the foreground, but a variant
    /// using `open -a` returns immediately — and `open` returns before the
    /// application is even observable, so a bare check would restore into the
    /// gap and hand the game vanilla archives.
    static func waitForGameToFinish(game: GameInstall, watcher: GameWatcher) {
        let executable = GameProcess.executable(in: game)

        if GameProcess.runningPIDs(matching: executable).isEmpty {
            // The game already ran and quit — the ordinary foreground case.
            // Waiting the full grace period here would tax every launch.
            if watcher.everSeen {
                // A process listing taken exactly as the launcher exits can
                // briefly miss a still-live game. Give the watcher a few
                // polling intervals to settle before restoring the archives.
                let settleDeadline = Date().addingTimeInterval(GameProcess.pollInterval * 4)
                while Date() < settleDeadline {
                    Thread.sleep(forTimeInterval: GameProcess.pollInterval)
                    if !GameProcess.runningPIDs(matching: executable).isEmpty {
                        break
                    }
                }
                if GameProcess.runningPIDs(matching: executable).isEmpty { return }
            }
            guard GameProcess.waitForStart(matching: executable) else { return }
        }

        print("The launcher exited but the game is still running; waiting for it...")
        GameProcess.waitForExit(matching: executable)
    }

    static func restore(store: BaselineStore, ledger: ArtifactLedger) throws {
        _ = try store.restore()
        try ledger.removeRecorded()
    }

    static func restoreQuietly(store: BaselineStore, ledger: ArtifactLedger) -> Error? {
        do {
            print("Restoring the baseline...")
            try restore(store: store, ledger: ledger)
            return nil
        } catch {
            return error
        }
    }

    static func recordExistingManagedArtifact(game: GameInstall, ledger: ArtifactLedger) throws {
        let artifact = game.managedLooseArchive
        guard FileManager.default.fileExists(atPath: artifact.path) else { return }
        try ledger.record([artifact])
    }

    static func reportRestoreFailure(_ error: Error, game: GameInstall, launcherCode: Int32 = 0) {
        fputs("\n", stderr)
        // Deliberately not "the install is patched": with zero mods nothing was
        // patched, and claiming otherwise would send the user hunting a problem
        // they do not have. What is certain is that the archives were not
        // returned to the baseline.
        fputs("error: RESTORE FAILED — the archives were not returned to the baseline\n", stderr)
        fputs("error: \(error)\n", stderr)
        if launcherCode != 0 {
            fputs("note: the launcher also exited \(launcherCode), which is the lesser problem\n", stderr)
        }
        fputs("\n", stderr)
        fputs("Recover with:\n", stderr)
        fputs("  cd \(shellQuote(game.root.path))\n", stderr)
        fputs("  ./archive-loader/bin/archive-loader run -- /usr/bin/true\n", stderr)
        fputs("\n", stderr)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private final class LockedProcessTarget: @unchecked Sendable {
    private let mutex = NSLock()
    private var pid: pid_t?

    var value: pid_t? {
        get {
            mutex.lock()
            defer { mutex.unlock() }
            return pid
        }
        set {
            mutex.lock()
            pid = newValue
            mutex.unlock()
        }
    }
}
