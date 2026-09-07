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
        log: SessionLog
    ) throws {
        log.info("Rebaseline: game version unchanged (\(candidate.version))")

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
        _ = try store.restore()

        let afterRestore = try store.compareLive(deep: true)
        guard afterRestore.isPristine else {
            throw CLIError.usage(
                "the archives still differ from the baseline after restoring it:\n"
                    + afterRestore.drifted.map { "  \($0)" }.joined(separator: "\n")
                    + "\n\nNothing further was changed."
            )
        }

        log.step("Capturing a new generation...")
        let manifest = try store.capture(
            gameVersion: candidate.version,
            storefront: candidate.sources.joined(separator: "+")
        )
        try store.publish(manifest)
        log.info("Baseline \(manifest.archives.count) archives recaptured")
        log.info()
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
