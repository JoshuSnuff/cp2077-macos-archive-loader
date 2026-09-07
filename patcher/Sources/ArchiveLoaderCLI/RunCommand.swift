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
        var useCache = true
        var explicitGame: String?
        var debug = ProcessInfo.processInfo.environment["ARCHIVE_LOADER_DEBUG"] == "1"

        // Everything after `--` belongs to the launcher, untouched.
        var wrapped: [String] = []
        if let separator = arguments.firstIndex(of: "--") {
            wrapped = Array(arguments[(separator + 1)...])
            arguments = Array(arguments[..<separator])
        }

        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--debug":
                debug = true
                index += 1
            case "--vanilla-on-error":
                vanillaOnError = true
                index += 1
            case "--no-cache":
                useCache = false
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
                "usage: archive-loader run [--debug] [--vanilla-on-error] [--no-cache] [--game GAME_DIR] -- <launcher> [args...]"
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
        let log = try SessionLog(command: "run", logsDirectory: game.logsDirectory, debug: debug)

        try reportingErrors(to: log) {
            try runResolved(
                game: game,
                candidate: candidate,
                store: store,
                ledger: ledger,
                launcher: launcher,
                launcherArguments: launcherArguments,
                vanillaOnError: vanillaOnError,
                useCache: useCache,
                log: log
            )
        }
    }

    private static func runResolved(
        game: GameInstall,
        candidate: GameCandidate,
        store: BaselineStore,
        ledger: ArtifactLedger,
        launcher: URL,
        launcherArguments: [String],
        vanillaOnError: Bool,
        useCache: Bool,
        log: SessionLog
    ) throws {

        // Refused before the lock so a live session gets the clearer message.
        try GameRunningGuard.refuseIfRunning(
            game: game,
            alreadyRunning: true,
            consequence: "restoring now would rewrite archives underneath it"
        )

        let lock = try InstallationLock.acquire(game: game)
        defer { lock.release() }
        var timingSummaryReported = false
        defer {
            reportTimingsIfNeeded(log: log, alreadyReported: &timingSummaryReported)
        }

        // The game could have started during lock acquisition. Never restore
        // under a session that won the race after the initial pre-lock check.
        try GameRunningGuard.refuseIfRunning(
            game: game,
            alreadyRunning: true,
            consequence: "restoring now would rewrite archives underneath it"
        )

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
        log.step("Restoring \(manifest.archives.count) archives...")
        do {
            try log.timed("restore") { try restore(store: store, ledger: ledger) }
        } catch {
            reportTimingsIfNeeded(log: log, alreadyReported: &timingSummaryReported)
            reportRestoreFailure(error, game: game, log: log)
            exitAfterReporting(
                restoreFailureExitCode,
                log: log,
                timingSummaryReported: &timingSummaryReported
            )
        }

        // 2. Patch, unless there is nothing to patch.
        let mods = try ModCollection.enabledMods(game: game)
        var patchedArchives: Set<URL> = []
        if mods.isEmpty {
            // Not an error: a no-mod run still restores, cleans up, and
            // launches. It is the normal way to play unmodded through the
            // same command, and `patch` rejects an empty --mods list anyway.
            log.info("No mods in \(game.modsEnabledDirectory.path); launching unmodded")
        } else {
            do {
                patchedArchives = try patchAndVerify(
                    mods: mods,
                    game: game,
                    manifest: manifest,
                    store: store,
                    ledger: ledger,
                    useCache: useCache,
                    log: log
                )
            } catch {
                let patchError = error
                // Patch and verification can fail after writing some files.
                // Recover before surfacing either failure or falling back.
                do {
                    try recordExistingManagedArtifact(game: game, ledger: ledger)
                } catch {
                    reportTimingsIfNeeded(log: log, alreadyReported: &timingSummaryReported)
                    reportRestoreFailure(error, game: game, log: log)
                    exitAfterReporting(
                        restoreFailureExitCode,
                        log: log,
                        timingSummaryReported: &timingSummaryReported
                    )
                }
                if let restoreError = restoreQuietly(store: store, ledger: ledger, log: log) {
                    reportTimingsIfNeeded(log: log, alreadyReported: &timingSummaryReported)
                    reportRestoreFailure(restoreError, game: game, log: log)
                    exitAfterReporting(
                        restoreFailureExitCode,
                        log: log,
                        timingSummaryReported: &timingSummaryReported
                    )
                }

                guard vanillaOnError else {
                    throw CLIError.usage(
                        "\(patchError)\n\nThe launch was aborted and the install left pristine."
                            + " Pass --vanilla-on-error to launch unmodded instead."
                    )
                }
                log.warning("\(patchError)")
                log.warning("--vanilla-on-error given; restoring and launching unmodded")
                do {
                    try restore(store: store, ledger: ledger)
                } catch {
                    reportTimingsIfNeeded(log: log, alreadyReported: &timingSummaryReported)
                    reportRestoreFailure(error, game: game, log: log)
                    exitAfterReporting(
                        restoreFailureExitCode,
                        log: log,
                        timingSummaryReported: &timingSummaryReported
                    )
                }
            }
        }

        // 3. Launch, then restore on every path out.
        var outcome: LaunchOutcome

        // Started before the launcher so that a foreground launcher's session
        // is observed while it happens.
        let watcher = GameWatcher(
            executable: GameProcess.executable(in: game),
            gameRoot: game.root,
            expectedArchives: patchedArchives
        )
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
            if let restoreError = restoreQuietly(store: store, ledger: ledger, log: log) {
                reportTimingsIfNeeded(log: log, alreadyReported: &timingSummaryReported)
                reportRestoreFailure(restoreError, game: game, log: log)
                exitAfterReporting(
                    restoreFailureExitCode,
                    log: log,
                    timingSummaryReported: &timingSummaryReported
                )
            }
            throw error
        }

        launcherTarget.value = nil
        waitForGameToFinish(game: game, watcher: watcher, log: log)
        watcher.stop()
        reportArchiveObservations(watcher.archiveObservation, game: game, log: log)
        if let interval = watcher.timeToFirstSighting {
            log.info(String(format: "The game appeared %.1fs after the launcher started", interval))
        }
        let restoreError = restoreQuietly(store: store, ledger: ledger, log: log)

        let launcherCode = outcome.wasSignalled
            ? outcome.reportableCode
            : signalForwarder.receivedSignal.map { 128 + $0 } ?? outcome.reportableCode
        if let restoreError {
            reportTimingsIfNeeded(log: log, alreadyReported: &timingSummaryReported)
            reportRestoreFailure(restoreError, game: game, launcherCode: launcherCode, log: log)
            exitAfterReporting(
                restoreFailureExitCode,
                log: log,
                timingSummaryReported: &timingSummaryReported
            )
        }
        if launcherCode != 0 {
            exitAfterReporting(
                launcherCode,
                log: log,
                timingSummaryReported: &timingSummaryReported
            )
        }
    }

    /// The launcher is normally given relative to the game directory, which is
    /// also the working directory the child gets.
    static func resolveLauncher(_ path: String, gameRoot: URL) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return gameRoot.appending(path: path).standardizedFileURL
    }

    static func patchAndVerify(
        mods: [URL],
        game: GameInstall,
        manifest: BaselineManifest,
        store: BaselineStore,
        ledger: ArtifactLedger,
        useCache: Bool,
        log: SessionLog
    ) throws -> Set<URL> {
        log.step("Patching with \(mods.count) mods...")
        for mod in mods {
            log.detail(mod.lastPathComponent)
        }

        let cache = PatchCacheStore(game: game)
        let officialArchives = try game.officialMacArchives()

        // Computed before anything is written, from the just-restored install.
        var fingerprint: CacheFingerprint?
        if useCache {
            do {
                let computed = try CacheFingerprint.compute(
                    game: game,
                    manifest: manifest,
                    officialArchives: officialArchives,
                    mods: mods
                )
                fingerprint = computed
                log.debug { "cache fingerprint \(computed.value)\n\(computed.canonicalInput)" }
            } catch {
                // A cache is never worth failing a launch over.
                log.warning("could not fingerprint the patch cache: \(error)")
            }
        }

        // Built from the baseline in both cases, and before any cached archive
        // is cloned over a live one.
        let plan = try log.timed("plan") {
            try PatchPlanner.plan(mods: mods, officialArchives: officialArchives)
        }
        for loser in plan.losers {
            log.detail(
                "conflict: \(Hashes.hex64(loser.hash)) in \(loser.modArchive.lastPathComponent)"
                    + " loses to \(loser.winnerArchive.lastPathComponent)"
            )
        }
        for hash in plan.winners.keys.sorted() {
            guard let winner = plan.winners[hash] else { continue }
            let owners = plan.officialWork
                .filter { $0.value.contains(hash) }
                .map(\.key.lastPathComponent)
                .sorted()
                .joined(separator: ",")
            log.debug {
                let record = winner.record
                return "resource \(Hashes.hex64(hash)) mod=\(winner.modArchive.lastPathComponent)"
                    + " owners=[\(owners)] segments=\(record.segmentsStart)..<\(record.segmentsEnd)"
                    + " dependencies=\(record.dependenciesStart)..<\(record.dependenciesEnd)"
            }
        }

        // Non-nil exactly while this run is standing on a cached image. It is
        // what the retry below discards, and clearing it is what bounds the
        // retry to one attempt.
        var cacheHit: CacheFingerprint?
        var patched: [URL]

        var cached: CacheManifest?
        if let fingerprint {
            do {
                cached = try cache.lookUp(fingerprint)
            } catch {
                log.warning("could not look up the patch cache: \(error)")
            }
        }

        if let fingerprint, let cached {
            do {
                patched = try log.timed("clone") {
                    try cache.apply(cached, fingerprint: fingerprint)
                }
                if let loosePath = cached.looseArchive {
                    try ledger.record([game.macArchiveDirectory.appending(path: loosePath)])
                }
                cacheHit = fingerprint
                log.info("Reused the cached patched image (\(patched.count) archives)")
            } catch {
                // apply() can have replaced some archives before a later
                // clone fails. The cache is optional, but the live install
                // must be returned to the baseline before patching normally.
                log.warning("could not apply the cached patched image: \(error)")
                try recordExistingManagedArtifact(game: game, ledger: ledger)
                try restore(store: store, ledger: ledger)
                patched = try applyPlan(plan: plan, game: game, ledger: ledger, log: log)
            }
        } else {
            patched = try applyPlan(plan: plan, game: game, ledger: ledger, log: log)
        }

        // Unchanged on both paths: a cache hit is held to exactly the standard
        // a fresh patch is held to, which is what keeps the fingerprint a
        // performance input rather than a correctness one.
        var report: VerificationReport?
        do {
            report = try log.timed("verify") { try PlanVerifier.verify(plan: plan, game: game) }
        } catch {
            // A cached archive damaged badly enough that it will not parse
            // makes the verifier throw rather than report. On the cache path
            // that is still just a bad generation; anywhere else it is the
            // existing failure.
            guard cacheHit != nil else { throw error }
            log.warning("the cached patched image could not be read: \(error)")
        }

        if let hit = cacheHit, report?.isClean != true {
            // The generation is wrong or damaged. It must cost a slow launch,
            // never a failed one.
            log.warning("the cached patched image failed verification; discarding it and patching")
            if let report { reportVerificationFailure(report, log: log) }
            do {
                try cache.discard(hit)
            } catch {
                log.warning("could not discard the cached patched image: \(error)")
            }
            try restore(store: store, ledger: ledger)
            patched = try applyPlan(plan: plan, game: game, ledger: ledger, log: log)
            cacheHit = nil
            report = try log.timed("verify") { try PlanVerifier.verify(plan: plan, game: game) }
        }

        guard let report, report.isClean else {
            if let report { reportVerificationFailure(report, log: log) }
            throw CLIError.usage("verification failed after patching")
        }
        log.info(
            "Verified \(report.matchingRecordCount) records match the plan"
                + " across \(report.archives.count) archives"
        )

        if let fingerprint, cacheHit == nil {
            do {
                let stored = try log.timed("cache") {
                    try cache.store(
                        fingerprint: fingerprint,
                        baseline: manifest,
                        patchedArchives: patched,
                        looseArchive: patched.first { $0 == game.managedLooseArchive.normalizedFileURL }
                    )
                }
                log.info("Cached the patched image (\(stored.archives.count) archives)")
            } catch {
                log.warning("could not cache the patched image: \(error)")
            }
        }

        return Set(patched.map(\.normalizedFileURL))
    }

    /// The write half of a run: rewrite the official archives the plan names.
    private static func applyPlan(
        plan: PatchPlan,
        game: GameInstall,
        ledger: ArtifactLedger,
        log: SessionLog
    ) throws -> [URL] {
        let summary = try log.timed("patch") { try RDARPatcher(game: game).apply(plan: plan) }
        if let loose = summary.looseArchive {
            try ledger.record([loose])
        }
        log.info("Patched \(summary.overrideRecordCount) records across \(summary.archives.count) archives")
        return (summary.archives.map(\.targetArchive) + [summary.looseArchive].compactMap { $0 })
            .map(\.normalizedFileURL)
    }

    private static func reportVerificationFailure(_ report: VerificationReport, log: SessionLog) {
        for archive in report.archives where !archive.isClean {
            log.detail("BAD \(archive.archive.lastPathComponent)")
            for issue in archive.issues {
                log.detail("    ! \(issue)")
            }
        }
    }

    /// The launcher exiting is not the session ending.
    ///
    /// Both upstream launchers run the game in the foreground, but a variant
    /// using `open -a` returns immediately — and `open` returns before the
    /// application is even observable, so a bare check would restore into the
    /// gap and hand the game vanilla archives.
    static func waitForGameToFinish(game: GameInstall, watcher: GameWatcher, log: SessionLog) {
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

        log.info("The launcher exited but the game is still running; waiting for it...")
        GameProcess.waitForExit(matching: executable)
    }

    static func restore(store: BaselineStore, ledger: ArtifactLedger) throws {
        _ = try store.restore()
        try ledger.removeRecorded()
    }

    static func restoreQuietly(
        store: BaselineStore,
        ledger: ArtifactLedger,
        log: SessionLog
    ) -> Error? {
        do {
            log.step("Restoring the baseline...")
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

    static func reportRestoreFailure(
        _ error: Error,
        game: GameInstall,
        launcherCode: Int32 = 0,
        log: SessionLog
    ) {
        log.stderr()
        // Deliberately not "the install is patched": with zero mods nothing was
        // patched, and claiming otherwise would send the user hunting a problem
        // they do not have. What is certain is that the archives were not
        // returned to the baseline.
        log.failure("\(error)")
        if launcherCode != 0 {
            log.note("the launcher also exited \(launcherCode), which is the lesser problem")
        }
        log.stderr()
        log.stderr("Recover with:")
        log.stderr("  cd \(shellQuote(game.root.path))")
        log.stderr("  ./archive-loader/bin/archive-loader run -- /usr/bin/true")
        log.stderr()
        // Keep the load-bearing failure as the durable tail: exit(3) below
        // bypasses deferred cleanup.
        log.failure("RESTORE FAILED — the archives were not returned to the baseline")
    }

    private static func reportArchiveObservations(
        _ observation: ArchiveObservation,
        game: GameInstall,
        log: SessionLog
    ) {
        guard !observation.expected.isEmpty else { return }
        let relative: (URL) -> String = { url in
            let prefix = game.root.appending(path: "archive/Mac").normalizedFileURL.path + "/"
            return url.normalizedFileURL.path.hasPrefix(prefix)
                ? String(url.normalizedFileURL.path.dropFirst(prefix.count))
                : url.lastPathComponent
        }
        log.info("Game opened \(observation.observed.count) of \(observation.expected.count) patched archives")
        for archive in observation.expected.sorted(by: { $0.path < $1.path }) {
            log.detail("\(relative(archive))  \(observation.observed.contains(archive) ? "opened" : "not observed")")
        }
        log.debug {
            "archive sample 1=[\(observation.samples.first?.map(\.path).sorted().joined(separator: ",") ?? "")]"
        }
        log.debug {
            "archive sample 2=[\(observation.samples.dropFirst().first?.map(\.path).sorted().joined(separator: ",") ?? "")]"
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func reportTimingsIfNeeded(log: SessionLog, alreadyReported: inout Bool) {
        guard !alreadyReported else { return }
        log.reportTimings()
        alreadyReported = true
    }

    private static func exitAfterReporting(
        _ status: Int32,
        log: SessionLog,
        timingSummaryReported: inout Bool
    ) -> Never {
        reportTimingsIfNeeded(log: log, alreadyReported: &timingSummaryReported)
        exit(status)
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
