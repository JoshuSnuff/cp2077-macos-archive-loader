import CP2077ArchiveCore
import Foundation

/// Replacing a baseline, which is two different operations wearing one flag.
///
/// Same game version: the recorded bytes and the live bytes are the same
/// generation of the game, so restoring first is correct and gives a clean
/// starting point to recapture from.
///
/// Changed game version: the recorded baseline holds the *old* build's
/// archives. Applying them over an updated installation overwrites the new
/// data files while leaving the new executable in place, and then records
/// those stale bytes against the new version string — corrupting the install
/// and recording the corruption as vanilla. This path never restores.
enum Rebaseline {
    static func run(
        game: GameInstall,
        store: BaselineStore,
        candidate: GameCandidate,
        assumeClean: Bool,
        trustLiveTweaks: Bool,
        log: SessionLog
    ) throws {
        guard let existing = try store.publishedManifest() else {
            log.info("No baseline is published; capturing a first one.")
            try SetupCommand.capture(
                game: game,
                store: store,
                candidate: candidate,
                assumeClean: assumeClean,
                log: log
            )
            return
        }

        let versionChanged = existing.gameVersion != candidate.version
        if versionChanged, trustLiveTweaks {
            throw CLIError.usage(
                "--trust-live-tweaks only applies to same-version archive-only baselines"
            )
        }
        let evidence = try NegativeEvidence.inspect(game: game)
        // The published baseline is itself a finding for a first capture, but
        // replacing one is the whole point here.
        let artifacts = evidence.findings.filter {
            if case .publishedBaseline = $0 { return false }
            return true
        }

        if versionChanged {
            try changedVersion(
                game: game,
                store: store,
                candidate: candidate,
                existing: existing,
                artifacts: artifacts,
                assumeClean: assumeClean,
                log: log
            )
        } else {
            try sameVersion(
                game: game,
                store: store,
                candidate: candidate,
                existing: existing,
                assumeClean: assumeClean,
                trustLiveTweaks: trustLiveTweaks,
                log: log
            )
        }
    }

    private static func sameVersion(
        game: GameInstall,
        store: BaselineStore,
        candidate: GameCandidate,
        existing: BaselineManifest,
        assumeClean: Bool,
        trustLiveTweaks: Bool,
        log: SessionLog
    ) throws {
        log.info("Rebaseline: game version unchanged (\(candidate.version))")

        if existing.tweaks.isEmpty, !game.tweakBlobs().isEmpty {
            guard trustLiveTweaks else {
                throw CLIError.usage(
                    "the published baseline predates TweakDB capture; refusing to record live tweak blobs"
                        + ". Run storefront verification, then archive-loader setup --rebaseline"
                        + " --trust-live-tweaks."
                )
            }
        }

        let comparison = try store.compareLive(deep: false)
        guard comparison.isRestorable else {
            throw CLIError.usage(
                "the published baseline records archives that are no longer present, so it"
                    + " cannot be restored:\n"
                    + comparison.missing.map { "  \($0)" }.joined(separator: "\n")
                    + "\n\nRun your storefront's verify/repair, then try again."
                    + " Nothing was changed."
            )
        }

        log.step("Restoring \(existing.archives.count) archives from the published baseline...")
        try RunCommand.restore(store: store, ledger: ArtifactLedger(game: game))

        let afterRestore = try store.compareLive(deep: true)
        guard afterRestore.isPristine else {
            throw CLIError.usage(
                "the archives still differ from the baseline after restoring it:\n"
                    + afterRestore.drifted.map { "  \($0)" }.joined(separator: "\n")
                    + "\n\nNothing further was changed."
            )
        }

        log.step("Capturing a new generation...")
        let manifest: BaselineManifest
        if trustLiveTweaks, existing.tweaks.isEmpty, !game.tweakBlobs().isEmpty {
            manifest = try captureTrustedLegacyBaseline(
                game: game,
                store: store,
                gameVersion: candidate.version,
                storefront: candidate.sources.joined(separator: "+")
            )
        } else {
            manifest = try store.capture(
                gameVersion: candidate.version,
                storefront: candidate.sources.joined(separator: "+")
            )
        }
        try store.publish(manifest)
        log.info("Baseline \(manifest.archives.count) archives recaptured")
        log.info()
    }

    /// Captures a legacy archive-only baseline's live TweakDB blobs only after
    /// the caller has compared, restored, and re-verified the archives.
    ///
    /// BaselineStore.capture deliberately rejects this combination for every
    /// ordinary capture call. The explicit CLI trust flag reaches this private
    /// path only after same-version rebaseline has established the archive
    /// safety conditions above.
    private static func captureTrustedLegacyBaseline(
        game: GameInstall,
        store: BaselineStore,
        gameVersion: String,
        storefront: String
    ) throws -> BaselineManifest {
        let manager = FileManager.default
        let archives = try game.officialMacArchives()
        guard !archives.isEmpty else {
            throw BaselineError.noOfficialArchives(game.macContentArchiveDirectory)
        }

        try manager.createDirectory(at: game.baselinesDirectory, withIntermediateDirectories: true)
        let id = try trustedGenerationID(store: store)
        let generation = store.generationDirectory(id: id)
        try manager.createDirectory(at: generation, withIntermediateDirectories: false)

        var archiveEntries: [BaselineEntry] = []
        for archive in archives {
            let relativePath = relativeArchivePath(archive)
            let destination = generation.appending(path: relativePath)
            try manager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Clone.file(from: archive, to: destination)
            archiveEntries.append(try baselineEntry(path: relativePath, file: destination))
        }

        var tweakEntries: [BaselineEntry] = []
        for blob in game.tweakBlobs() {
            let relativePath = relativeTweakPath(blob, game: game)
            let destination = generation.appending(path: relativePath)
            try manager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Clone.file(from: blob, to: destination)
            tweakEntries.append(try baselineEntry(path: relativePath, file: destination))
        }

        let manifest = BaselineManifest(
            id: id,
            capturedAt: ISO8601DateFormatter().string(from: Date()),
            gameVersion: gameVersion,
            storefront: storefront,
            loaderVersion: LoaderVersion.current,
            archives: archiveEntries.sorted { $0.path < $1.path },
            tweaks: tweakEntries.sorted { $0.path < $1.path }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: generation.appending(path: "baseline.json"),
            options: .atomic
        )
        return manifest
    }

    private static func trustedGenerationID(store: BaselineStore) throws -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: Date())

        var candidate = stamp
        var attempt = 0
        while FileManager.default.fileExists(atPath: store.generationDirectory(id: candidate).path) {
            attempt += 1
            candidate = String(format: "%@-%04d", stamp, attempt)
        }
        return candidate
    }

    private static func baselineEntry(path: String, file: URL) throws -> BaselineEntry {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        return BaselineEntry(
            path: path,
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            sha256: try Hashes.sha256Hex(ofFileAt: file)
        )
    }

    private static func relativeArchivePath(_ archive: URL) -> String {
        "\(archive.deletingLastPathComponent().lastPathComponent)/\(archive.lastPathComponent)"
    }

    private static func relativeTweakPath(_ blob: URL, game: GameInstall) -> String {
        let root = game.root.standardizedFileURL.path + "/"
        return String(blob.standardizedFileURL.path.dropFirst(root.count))
    }

    private static func changedVersion(
        game: GameInstall,
        store: BaselineStore,
        candidate: GameCandidate,
        existing: BaselineManifest,
        artifacts: [NegativeEvidence.Finding],
        assumeClean: Bool,
        log: SessionLog
    ) throws {
        log.info("Rebaseline: game version changed \(existing.gameVersion) -> \(candidate.version)")
        log.info("            the recorded archives belong to the old build, so nothing is restored")
        log.info()

        if TweakWriteMarker.exists(game: game) {
            throw CLIError.usage(
                "the previous run left a durable TweakDB write marker at "
                    + "\(TweakWriteMarker.url(game: game).path)."
                    + " Run archive-loader restore or storefront verify/repair before"
                    + " setup --rebaseline. Nothing was changed."
            )
        }

        guard artifacts.isEmpty else {
            // Neither path is available: restoring would write the old build
            // over the new one, and capturing would record a patched install.
            throw CLIError.usage(
                "the game has been updated while loader artifacts are still present:\n"
                    + NegativeEvidence(findings: artifacts).summary
                    + "\n\nNeither recovery is safe here — restoring would write the old build's"
                    + "\narchives over the new installation, and capturing would record a patched"
                    + "\ninstall as vanilla."
                    + "\n\nRun your storefront's verify/repair to return the game to a clean state,"
                    + "\nthen run: archive-loader setup --rebaseline"
                    + "\n\nNothing was changed."
            )
        }

        guard assumeClean || SetupCommand.confirmStorefrontVerify(log: log) else {
            throw CLIError.usage("setup needs that confirmation to continue; nothing was changed")
        }

        log.step("Capturing a new generation from the updated installation...")
        let manifest = try store.capture(
            gameVersion: candidate.version,
            storefront: candidate.sources.joined(separator: "+")
        )
        try store.publish(manifest)
        log.info("Baseline \(manifest.archives.count) archives captured for \(candidate.version)")
        log.info()
    }
}
