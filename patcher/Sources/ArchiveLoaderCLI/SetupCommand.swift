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
        let trustLiveTweaks = args.contains("--trust-live-tweaks")
        let runtimePackagePath = options.value("--runtime-package")
        let debug = args.contains("--debug")
            || ProcessInfo.processInfo.environment["ARCHIVE_LOADER_DEBUG"] == "1"

        if args.contains("--runtime-package") && runtimePackagePath == nil {
            throw CLIError.missingValue("--runtime-package")
        }

        guard !trustLiveTweaks || rebaseline else {
            throw CLIError.usage("--trust-live-tweaks requires --rebaseline")
        }

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
                trustLiveTweaks: trustLiveTweaks,
                runtimePackageRoot: runtimePackagePath.map {
                    URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
                },
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
        trustLiveTweaks: Bool,
        runtimePackageRoot: URL?,
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

        // Recover an interrupted compatibility transaction before inspecting
        // capabilities or considering a new package. Recovery is the only
        // mutation allowed before the preflight gates below.
        _ = try game.installationTransactionService.recoverAtStartup()

        let requirements = try ModFrameworkRequirements.classify(game: game)
        let activeRuntime = try FrameworkRuntimeSupport.active(game: game)
        let package = try prepareRuntimePackage(
            game: game,
            packageRoot: runtimePackageRoot,
            activeRuntime: activeRuntime
        )

        if !requirements.runtimeOwnedMods.isEmpty,
           package?.document.manifest.frameworkRuntime == nil,
           activeRuntime == nil {
            throw CLIError.usage(
                "framework-dependent mods were found, but no verified compatibility runtime is active."
                    + " Install one with setup --runtime-package PATH"
            )
        }

        log.info("Game     \(game.root.path)")
        log.info("Version  \(candidate.version)  (\(candidate.sources.joined(separator: "+")))")
        log.info()

        // This must precede baseline restore/capture and any package write.
        try runPreflight(game: game, log: log)

        if let package {
            try installCompatibilityPackage(
                package: package,
                game: game,
                log: log
            )
        }

        if rebaseline {
            try Rebaseline.run(
                game: game,
                store: store,
                candidate: candidate,
                assumeClean: assumeClean,
                trustLiveTweaks: trustLiveTweaks,
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

    private struct RuntimePackage {
        let root: URL
        let document: CompatibilityManifestDocument
        let identity: CompatibilityIdentity
    }

    /// Validate a requested package without mutating the game. The source root
    /// is the package directory itself, matching the existing compatibility
    /// package layout; an installed manifest is only used as a legacy package
    /// source when no explicit package was requested.
    private static func prepareRuntimePackage(
        game: GameInstall,
        packageRoot: URL?,
        activeRuntime: ActiveFrameworkRuntime?
    ) throws -> RuntimePackage? {
        let root: URL?
        if let packageRoot {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: packageRoot.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                throw CLIError.usage("runtime package is not a directory: \(packageRoot.path)")
            }
            root = packageRoot
        } else if activeRuntime == nil {
            let installedManifest = game.compatibilityManifestURL
            root = FileManager.default.isReadableFile(atPath: installedManifest.path)
                ? game.root
                : nil
        } else {
            root = nil
        }

        guard let root else { return nil }
        let manifestURL = root.appending(path: "archive-loader/compatibility/manifest.json")
        guard FileManager.default.isReadableFile(atPath: manifestURL.path) else {
            throw CLIError.usage(
                "runtime package is missing archive-loader/compatibility/manifest.json: \(root.path)"
            )
        }
        let document = try CompatibilityManifestDocument(bytes: Data(contentsOf: manifestURL))
        guard document.manifest.frameworkRuntime != nil else {
            if packageRoot != nil {
                throw CLIError.usage(
                    "requested runtime package does not declare frameworkRuntime; refusing to fall back"
                )
            }
            let identity = try CompatibilityIdentityReader.read(root: game.root, manifest: document.manifest)
            try CompatibilityIdentityValidator.requireMatch(target: document.manifest.target, actual: identity)
            _ = try CompatibilityPackageValidator.validate(
                manifest: document.manifest,
                packageRoot: root
            )
            return RuntimePackage(root: root, document: document, identity: identity)
        }
        let identity = try CompatibilityIdentityReader.read(root: game.root, manifest: document.manifest)
        try CompatibilityIdentityValidator.requireMatch(target: document.manifest.target, actual: identity)
        _ = try CompatibilityPackageValidator.validate(
            manifest: document.manifest,
            packageRoot: root
        )
        return RuntimePackage(root: root, document: document, identity: identity)
    }

    private static func installCompatibilityPackage(
        package: RuntimePackage,
        game: GameInstall,
        log: SessionLog
    ) throws {
        let marker = try game.installationTransactionService.install(
            manifestDocument: package.document,
            packageRoot: package.root,
            verifiedIdentity: package.identity
        )
        log.info("Compatibility package installed transactionally (\(marker.transactionID))")
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
