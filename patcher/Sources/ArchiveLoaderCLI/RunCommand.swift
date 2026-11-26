import CP2077ArchiveCore
import Foundation

/// Exit code for a failed restore.
///
/// Deliberately outside the range a game or launcher would produce, so "your
/// install is still patched" can never be read as the game's own exit status.
private let restoreFailureExitCode: Int32 = 70

struct TweakBuildResult {
    let blobs: [URL]
    let plan: TweakPlan
    let fingerprint: CacheFingerprint
    let cacheHit: Bool
    let applied: Int
    let temporaryDirectory: URL?

    func removeTemporaryBuild() {
        guard let temporaryDirectory else { return }
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }
}

enum TweakBuildError: Error, CustomStringConvertible {
    case noTweakMods
    case noTweakBaseline
    case missingBaselineBlob(String)
    case archiveXL([String])
    case invalidOperation(String)
    case verificationFailed([String])

    var description: String {
        switch self {
        case .noTweakMods:
            return "no tweak mods were found"
        case .noTweakBaseline:
            return "the published baseline is archive-only and has no TweakDB blobs."
                + " Run: archive-loader setup --rebaseline"
        case let .missingBaselineBlob(path):
            return "the published baseline is missing TweakDB blob \(path)"
        case let .archiveXL(diagnostics):
            return "ArchiveXL is unsupported by this loader:\n"
                + diagnostics.map { "  \($0)" }.joined(separator: "\n")
        case let .invalidOperation(detail):
            return "tweak build failed: \(detail)"
        case let .verificationFailed(issues):
            return "TweakDB verification failed:\n"
                + issues.map { "  \($0)" }.joined(separator: "\n")
        }
    }
}

enum TweakWriteMarker {
    private struct Document: Codable {
        let schema: String
        let baselineID: String
        let blobs: [String]
        let writtenAt: String
    }

    static let fileName = "tweak-write.json"

    static func url(game: GameInstall) -> URL {
        game.stateDirectory.appending(path: fileName, directoryHint: .notDirectory)
    }

    static func exists(game: GameInstall) -> Bool {
        FileManager.default.fileExists(atPath: url(game: game).path)
    }

    static func write(game: GameInstall, baselineID: String, blobs: [String]) throws {
        let document = Document(
            schema: "archive-loader-tweak-write/v1",
            baselineID: baselineID,
            blobs: blobs.sorted(),
            writtenAt: ISO8601DateFormatter().string(from: Date())
        )
        try FileManager.default.createDirectory(
            at: game.stateDirectory,
            withIntermediateDirectories: true
        )
        let marker = url(game: game)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: marker, options: .atomic)
        let handle = try FileHandle(forWritingTo: marker)
        try handle.synchronize()
        try handle.close()
    }

    static func clear(game: GameInstall) throws {
        guard exists(game: game) else { return }
        try FileManager.default.removeItem(at: url(game: game))
    }
}

enum RunCommand {
    static func run(_ args: [String]) throws {
        var arguments = args
        var vanillaOnError = false
        var useCache = true
        var noTweaks = false
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
            case "--no-tweaks":
                noTweaks = true
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
                "usage: archive-loader run [--debug] [--vanilla-on-error] [--no-cache] [--no-tweaks] [--game GAME_DIR] -- <launcher> [args...]"
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
                noTweaks: noTweaks,
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
        noTweaks: Bool,
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

        // Reconcile any projection left by an interrupted prior session while
        // this command still owns the installation lock. This is deliberately
        // throwing: a tampered record or destination must block the run.
        try FrameworkModProjection.reconcile(game: game)

        // Reconcile compatibility transactions before reading the active
        // runtime. This is recovery work, not a new installation mutation.
        _ = try game.installationTransactionService.recoverAtStartup()

        let requirements = try ModFrameworkRequirements.classify(game: game)
        let activeRuntime = try FrameworkRuntimeSupport.active(
            game: game,
            requireFramework: !requirements.runtimeOwnedMods.isEmpty
        )

        // Every read-only gate must finish before restore, patching, TweakDB
        // delivery, or native framework projection begins.
        try SetupCommand.runPreflight(game: game, log: log)
        guard FileManager.default.isExecutableFile(atPath: launcher.path) else {
            throw LaunchError.notExecutable(launcher)
        }
        let launchEnvironment = try activeRuntime.map {
            try FrameworkRuntimeSupport.environment(for: $0.runtime, game: game)
        }

        // Compatibility is the authority for whether this installation may
        // be touched at all. Keep this before baseline restoration, patching,
        // watcher setup, and every path to LaunchSupervisor.run.
        try log.timed("compatibility") {
            let manifestURL = game.root.appending(
                path: "archive-loader/compatibility/manifest.json"
            )
            guard FileManager.default.isReadableFile(atPath: manifestURL.path) else { return }
            let compatibilityManifest = try CompatibilityManifest.load(from: manifestURL)
            let identity = try CompatibilityIdentityReader.read(root: game.root, manifest: compatibilityManifest)
            try CompatibilityIdentityValidator.requireMatch(target: compatibilityManifest.target, actual: identity)
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

        // Build the complete tweak image before the first live archive or
        // TweakDB write. The returned URLs remain stable until delivery, so
        // discovery, parsing, encoding, mutation, and verification all belong
        // to preflight rather than a partially applied launch.
        let tweakMods: [URL]
        var stagedTweaks: TweakBuildResult?
        if noTweaks {
            tweakMods = []
            stagedTweaks = nil
            log.info("Tweaks skipped (--no-tweaks)")
        } else {
            tweakMods = requirements.offlineMods
            if tweakMods.isEmpty {
                stagedTweaks = nil
                if manifest.tweaks.isEmpty {
                    log.note(
                        "the published baseline is archive-only; tweak mods are disabled"
                            + " until archive-loader setup --rebaseline captures TweakDB"
                    )
                }
            } else {
                guard !manifest.tweaks.isEmpty else {
                    throw TweakBuildError.noTweakBaseline
                }
                guard let result = try buildTweaks(
                    game: game,
                    useCache: useCache,
                    requirements: requirements,
                    log: { message in log.warning(message) }
                ) else {
                    throw TweakBuildError.noTweakMods
                }
                stagedTweaks = result
            }
        }
        defer { stagedTweaks?.removeTemporaryBuild() }

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
        let runtimeOwnedMods = Set(requirements.runtimeOwnedMods.map(\.standardizedFileURL))
        let mods = try ModCollection.enabledMods(game: game).filter {
            !runtimeOwnedMods.contains($0.standardizedFileURL)
        }
        var patchedArchives: Set<URL> = []
        var allowTweakDelivery = true
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
                    try FrameworkModProjection.restore(game: game)
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
                allowTweakDelivery = false
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

        // 3. Deliver the already verified TweakDB image only after the archive
        // layer succeeds. No tweak interpretation or mutation occurs here.
        if allowTweakDelivery, let result = stagedTweaks {
            do {
                try deliverTweaks(result, game: game, log: log)
                log.info(
                    "Tweaks: " + String(result.applied) + " operations from "
                        + String(result.plan.mods.count) + " mods"
                        + (result.cacheHit ? " (cache hit)" : "")
                )
                for loser in result.plan.losers {
                    log.detail(
                        "tweak conflict: " + loser.flat + " — " + loser.mod.lastPathComponent
                            + " loses to " + loser.winner.lastPathComponent
                    )
                }
            } catch {
                let tweakError = error
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
                        String(describing: tweakError)
                            + "\n\nThe launch was aborted and the install left pristine."
                            + " Pass --vanilla-on-error to launch unmodded instead."
                    )
                }
                log.warning(String(describing: tweakError))
                log.warning("--vanilla-on-error given; tweak layer skipped and launching vanilla")
            }
        }

        // Native framework files are session-scoped. Stage them after every
        // operation that can restore the baseline, so no later retry can
        // silently remove the files before the launcher starts.
        let projection: FrameworkModProjection?
        if !requirements.runtimeOwnedMods.isEmpty {
            projection = try FrameworkModProjection.stage(requirements: requirements, game: game)
            log.info("Projected \(projection?.entries.count ?? 0) framework file(s) for this session")
        } else {
            projection = nil
        }

        // 4. Launch, then restore on every path out.
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
            if let projection {
                try assertProjectionPresentForLaunch(projection)
            }
            outcome = try LaunchSupervisor.run(
                executable: launcher,
                arguments: launcherArguments,
                workingDirectory: game.root,
                environment: launchEnvironment,
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

    private static func assertProjectionPresentForLaunch(
        _ projection: FrameworkModProjection
    ) throws {
        for entry in projection.entries {
            let values = try entry.destination.resourceValues(
                forKeys: [.isSymbolicLinkKey, .isRegularFileKey]
            )
            guard FileManager.default.fileExists(atPath: entry.destination.path),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true
            else {
                throw CLIError.usage(
                    "framework projection is missing before launch: \(entry.destination.path)"
                )
            }
            guard try Hashes.sha256Hex(ofFileAt: entry.destination) == entry.sha256 else {
                throw CLIError.usage(
                    "framework projection changed before launch: \(entry.destination.path)"
                )
            }
        }
    }

    /// Builds from the published generation into the loader-owned tweak cache.
    /// It never reads a live blob as a source and never writes into r6/cache.
    static func buildTweaks(
        game: GameInstall,
        useCache: Bool,
        requirements: ModFrameworkRequirements? = nil,
        log: (String) -> Void = { print("warning: \($0)") }
    ) throws -> TweakBuildResult? {
        let requirements = try requirements ?? ModFrameworkRequirements.classify(game: game)
        let mods = requirements.offlineMods
        guard !mods.isEmpty else { return nil }

        let store = BaselineStore(game: game)
        guard let manifest = try store.publishedManifest(),
              store.publishedGeneration != nil else {
            throw BaselineError.noPublishedBaseline(game.pristinePointer)
        }
        guard !manifest.tweaks.isEmpty else {
            throw TweakBuildError.noTweakBaseline
        }

        let inventory = try ArchiveXLDetector.scan(mods: mods, game: game)
        guard inventory.isEmpty else {
            throw TweakBuildError.archiveXL(inventory.diagnostics)
        }

        let sources = try tweakSources(game: game, manifest: manifest, store: store)
        let plan = try TweakPlanner.plan(
            mods: mods,
            blobs: sources,
            requirements: requirements
        )
        let runtimeProjectionInputs = try runtimeProjectionInputs(for: requirements)
        let fingerprint = try TweakFingerprint.compute(
            game: game,
            manifest: manifest,
            mods: mods,
            inventory: inventory,
            requirements: requirements,
            runtimeProjectionInputs: runtimeProjectionInputs
        )
        let cache = TweakCacheStore(game: game)

        if useCache {
            do {
                if let cached = try cache.load(fingerprint) {
                    do {
                        try verifyTweaks(cached, plan: plan, sources: sources)
                        return TweakBuildResult(
                            blobs: cached,
                            plan: plan,
                            fingerprint: fingerprint,
                            cacheHit: true,
                            applied: plan.operationCount,
                            temporaryDirectory: nil
                        )
                    } catch {
                        log("tweak cache verification failed; rebuilding from the published baseline: \(error)")
                        try? FileManager.default.removeItem(at: cache.directory(for: fingerprint))
                    }
                } else if FileManager.default.fileExists(atPath: cache.directory(for: fingerprint).path) {
                    log("tweak cache is invalid; rebuilding from the published baseline")
                }
            } catch {
                log("tweak cache could not be read; rebuilding from the published baseline: \(error)")
            }
        }

        let staging = game.tweakCacheRoot
            .appending(path: ".build-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        do {
            var built: [URL] = []
            for source in sources {
                var blob = try TweakBlob.read(source)
                for work in plan.workByBlob[source.normalizedFileURL] ?? [] {
                    try apply(work.operation, to: &blob)
                }

                do {
                    try TweakVerifier.validate(blob)
                } catch {
                    throw TweakBuildError.verificationFailed([String(describing: error)])
                }

                let target = staging.appending(path: source.lastPathComponent)
                try TweakBlobWriter.write(blob, to: target)
                built.append(target)
            }
            try verifyTweaks(built, plan: plan, sources: sources)

            guard useCache else {
                return TweakBuildResult(
                    blobs: built,
                    plan: plan,
                    fingerprint: fingerprint,
                    cacheHit: false,
                    applied: plan.operationCount,
                    temporaryDirectory: staging
                )
            }

            do {
                try cache.store(built, for: fingerprint)
                let installed = try cache.load(fingerprint) ?? built
                try verifyTweaks(installed, plan: plan, sources: sources)
                try? FileManager.default.removeItem(at: staging)
                return TweakBuildResult(
                    blobs: installed,
                    plan: plan,
                    fingerprint: fingerprint,
                    cacheHit: false,
                    applied: plan.operationCount,
                    temporaryDirectory: nil
                )
            } catch {
                // Cache writes are optional. The freshly verified staging
                // generation remains usable for this run.
                log("tweak cache write failed; using the verified uncached build: \(error)")
                return TweakBuildResult(
                    blobs: built,
                    plan: plan,
                    fingerprint: fingerprint,
                    cacheHit: false,
                    applied: plan.operationCount,
                    temporaryDirectory: staging
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    static func runtimeProjectionInputs(
        for requirements: ModFrameworkRequirements
    ) throws -> [String] {
        try requirements.classifications
            .filter(\.isRuntimeOwned)
            .flatMap { classification in
                [classification.mod] + classification.associatedFiles
            }
            .sorted { utf8Precedes($0.path, $1.path) }
            .map { source in
                source.path + " " + (try Hashes.sha256Hex(ofFileAt: source))
            }
    }

    static func deliverTweaks(
        _ result: TweakBuildResult,
        game: GameInstall,
        log: SessionLog
    ) throws {
        let paths = result.blobs.map { $0.lastPathComponent }
        try TweakWriteMarker.write(
            game: game,
            baselineID: result.fingerprint.value,
            blobs: paths
        )
        do {
            for blob in result.blobs.sorted(by: { utf8Precedes($0.path, $1.path) }) {
                let destination = game.tweakCacheDirectory.appending(path: blob.lastPathComponent)
                try Clone.replaceFile(from: blob, to: destination)
                log.detail("tweak wrote " + destination.lastPathComponent)
            }
        } catch {
            // The marker deliberately remains until a verified restore proves
            // that every recorded baseline blob is back in place.
            throw error
        }
    }

    static func tweakSources(
        game: GameInstall,
        manifest: BaselineManifest,
        store: BaselineStore
    ) throws -> [URL] {
        try BaselineManifest.validateTweakEntries(manifest.tweaks)
        guard let generation = store.publishedGeneration else {
            throw BaselineError.noPublishedBaseline(game.pristinePointer)
        }

        return try manifest.tweaks.sorted { utf8Precedes($0.path, $1.path) }.map { entry in
            let source = generation.appending(path: entry.path).standardizedFileURL
            let prefix = generation.standardizedFileURL.path + "/"
            guard source.path.hasPrefix(prefix),
                  FileManager.default.isReadableFile(atPath: source.path) else {
                throw TweakBuildError.missingBaselineBlob(entry.path)
            }
            return source
        }
    }

    private static func verifyTweaks(
        _ blobs: [URL],
        plan: TweakPlan,
        sources: [URL]
    ) throws {
        let byName = Dictionary(uniqueKeysWithValues: blobs.map { ($0.lastPathComponent, $0) })
        for source in sources {
            guard let blobURL = byName[source.lastPathComponent] else {
                throw TweakBuildError.verificationFailed([
                    "missing generated blob \(source.lastPathComponent)"
                ])
            }
            let blob: TweakBlob
            do {
                blob = try TweakBlob.read(blobURL)
                try TweakVerifier.validate(blob)
            } catch {
                throw TweakBuildError.verificationFailed([
                    blobURL.lastPathComponent + ": " + String(describing: error)
                ])
            }

            for work in plan.workByBlob[source.normalizedFileURL] ?? [] {
                guard let located = blob.find(flat: work.operation.targetFlat) else {
                    throw TweakBuildError.verificationFailed([
                        work.operation.targetFlat + ": not present after patching"
                    ])
                }
                if case let .assign(_, _, literal) = work.operation {
                    let block = blob.blocks[located.blockIndex]
                    let stored = block.values[Int(block.entries[located.entryIndex].valueIndex)]
                    let expected = try encode(literal, as: block.type, flat: work.operation.targetFlat)
                    let matches: Bool
                    do {
                        matches = try TweakValueOrder.equivalent(stored, expected, type: block.type)
                    } catch {
                        throw TweakBuildError.verificationFailed([
                            work.operation.targetFlat + ": stored value could not be compared: "
                                + String(describing: error)
                        ])
                    }
                    guard matches else {
                        throw TweakBuildError.verificationFailed([
                            work.operation.targetFlat + ": stored value does not match the plan"
                        ])
                    }
                }
            }
        }
    }

    private static func apply(_ operation: TweakOperation, to blob: inout TweakBlob) throws {
        switch operation {
        case let .assign(flat, _, literal):
            guard let located = blob.find(flat: flat) else {
                throw TweakBuildError.invalidOperation("no flat named \(flat) exists in this blob")
            }
            let type = blob.blocks[located.blockIndex].type
            try blob.assign(flat: flat, value: encode(literal, as: type, flat: flat))

        case let .arrayAppend(flat, _, literals), let .arrayRemove(flat, _, literals):
            guard let located = blob.find(flat: flat),
                  case let .array(elementType) = blob.blocks[located.blockIndex].type else {
                throw TweakBuildError.invalidOperation("\(flat) is not an array flat")
            }
            let block = blob.blocks[located.blockIndex]
            let current = block.values[Int(block.entries[located.entryIndex].valueIndex)]
            var elements = try decodeArray(current, elementType: elementType)
            let values = try literals.map { try encode($0, as: elementType, flat: flat) }

            switch operation {
            case .arrayAppend:
                for value in values where !elements.contains(value) { elements.append(value) }
            case .arrayRemove:
                elements.removeAll { values.contains($0) }
            default:
                break
            }

            elements.sort {
                (try? TweakValueOrder.precedes($0, $1, type: elementType)) ?? false
            }
            try blob.assign(flat: flat, value: encodeArray(elements))
        }
    }

    private static func encodeArray(_ elements: [Data]) -> Data {
        var output = TweakPacked.encode(elements.count, wideFlag: false)
        for element in elements { output.append(element) }
        return output
    }

    private static func decodeArray(_ value: Data, elementType: TweakValueType) throws -> [Data] {
        let (count, start) = try TweakPacked.read(value, at: 0)
        var cursor = start
        var elements: [Data] = []
        elements.reserveCapacity(count)
        for _ in 0..<count {
            let (element, next) = try readValue(value, at: cursor, type: elementType)
            elements.append(element)
            cursor = next
        }
        guard cursor == value.count else {
            throw TweakBuildError.invalidOperation("array value contains trailing bytes")
        }
        return elements
    }

    private static func readValue(
        _ data: Data,
        at offset: Int,
        type: TweakValueType
    ) throws -> (Data, Int) {
        if let width = type.fixedWidth {
            guard offset >= 0, offset <= data.count, width <= data.count - offset else {
                throw TweakBuildError.invalidOperation("truncated \(type.typeName) value")
            }
            return (data.subdata(in: offset..<offset + width), offset + width)
        }
        if type.isStringLike {
            let (length, next) = try TweakPacked.read(data, at: offset)
            guard length >= 0, next <= data.count, length <= data.count - next else {
                throw TweakBuildError.invalidOperation("truncated \(type.typeName) value")
            }
            return (data.subdata(in: offset..<next + length), next + length)
        }
        guard let element = type.elementType else {
            throw TweakBuildError.invalidOperation("unsupported \(type.typeName) value")
        }
        let (count, start) = try TweakPacked.read(data, at: offset)
        var cursor = start
        for _ in 0..<count { cursor = try readValue(data, at: cursor, type: element).1 }
        guard cursor <= data.count else {
            throw TweakBuildError.invalidOperation("truncated \(type.typeName) value")
        }
        return (data.subdata(in: offset..<cursor), cursor)
    }

    private static func encode(
        _ literal: TweakLiteral,
        as type: TweakValueType,
        flat: String
    ) throws -> Data {
        func u32(_ value: UInt32) -> Data {
            withUnsafeBytes(of: value.littleEndian) { Data($0) }
        }
        func u64(_ value: UInt64) -> Data {
            withUnsafeBytes(of: value.littleEndian) { Data($0) }
        }
        func packed(_ text: String) -> Data {
            TweakPacked.encode(text.utf8.count, wideFlag: !text.isEmpty) + Data(text.utf8)
        }

        guard type != .color else {
            throw TweakBuildError.invalidOperation("\(flat) uses unsupported Color values")
        }
        switch (type, literal) {
        case let (.int32, .int(value)):
            return u32(UInt32(bitPattern: value))
        case let (.float, .float(value)):
            return u32(value.bitPattern)
        case let (.float, .int(value)):
            return u32(Float(value).bitPattern)
        case let (.bool, .bool(value)):
            return Data([value ? 1 : 0])
        case let (.string, .string(value)):
            return packed(value)
        case let (.cname, .string(value)), let (.cname, .cname(value)):
            return packed(value)
        case let (.tweakDBID, .string(value)), let (.tweakDBID, .tweakDBID(value)):
            let id = TweakBlob.tweakDBID(value)
            return u32(id.hash) + u32(id.length)
        case let (.locKeyWrapper, .int(value)):
            return u64(UInt64(UInt32(bitPattern: value)))
        case let (.locKeyWrapper, .locKey(value)):
            return u64(value)
        case let (.array(elementType), .array(values)):
            return encodeArray(try values.map { try encode($0, as: elementType, flat: flat) })
        default:
            throw TweakBuildError.invalidOperation(
                flat + " cannot take a " + type.typeName + " value from this document"
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
        // Projection files are session state. Cleanup is explicit and
        // throwing: a stale record, changed destination, or failed deletion
        // must not be hidden while the archives are reported as restored.
        try FrameworkModProjection.restore(game: store.game)
        _ = try store.restore()
        try ledger.removeRecorded()

        let archives = try store.compareLive(deep: true)
        guard archives.isPristine else {
            throw CLIError.usage(
                "archives still differ from the published baseline after restoration:\n"
                    + archives.drifted.map { "  \($0)" }.joined(separator: "\n")
            )
        }
        if let manifest = try store.publishedManifest(), !manifest.tweaks.isEmpty {
            let tweaks = try store.compareLiveTweaks(deep: true)
            guard tweaks.isPristine else {
                throw CLIError.usage(
                    "TweakDB blobs still differ from the published baseline after restoration:\n"
                        + tweaks.drifted.map { "  \($0)" }.joined(separator: "\n")
                )
            }
        }
        try TweakWriteMarker.clear(game: store.game)
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

private func utf8Precedes(_ left: String, _ right: String) -> Bool {
    Array(left.utf8).lexicographicallyPrecedes(Array(right.utf8))
}
