import CP2077ArchiveCore
import Foundation

enum RestoreCommand {
    static func run(_ args: [String]) throws {
        let options = try Options(args)
        let debug = args.contains("--debug")
            || ProcessInfo.processInfo.environment["ARCHIVE_LOADER_DEBUG"] == "1"
        let candidates = try GameDiscovery.resolve(
            explicitRoot: options.value("--game").map { URL(fileURLWithPath: $0, isDirectory: true) }
        )
        guard let candidate = candidates.first, candidates.count == 1 else {
            throw CLIError.usage("could not resolve a single game installation; pass --game")
        }

        let game = GameInstall(root: candidate.root)
        let store = BaselineStore(game: game)
        let ledger = ArtifactLedger(game: game)
        let log = try SessionLog(command: "restore", logsDirectory: game.logsDirectory, debug: debug)

        try reportingErrors(to: log) {
            try runResolved(game: game, store: store, ledger: ledger, candidate: candidate, log: log)
        }
    }

    private static func runResolved(
        game: GameInstall,
        store: BaselineStore,
        ledger: ArtifactLedger,
        candidate: GameCandidate,
        log: SessionLog
    ) throws {

        try GameRunningGuard.refuseIfRunning(
            game: game,
            consequence: "restoring now would rewrite archives underneath it"
        )

        let lock = try InstallationLock.acquire(game: game)
        defer { lock.release() }

        // The game can start while the lock is being acquired.
        try GameRunningGuard.refuseIfRunning(
            game: game,
            consequence: "restoring now would rewrite archives underneath it"
        )

        guard let manifest = try store.publishedManifest() else {
            throw CLIError.usage(
                "no baseline has been captured for this installation, so there is nothing"
                    + " to restore from. Run: archive-loader setup"
            )
        }

        // Deliberately does NOT refuse on a version mismatch. Recovery after a
        // crash is exactly when the install is in a state we would rather not
        // reason about, and the recorded bytes are the only vanilla we have.
        if manifest.gameVersion != candidate.version {
            log.warning("the baseline records \(manifest.gameVersion) but the game reports"
                + " \(candidate.version)")
            log.warning("restoring anyway — run `archive-loader setup --rebaseline` afterwards")
        }

        let comparison = try store.compareLive(deep: false)
        guard comparison.isRestorable else {
            throw CLIError.usage(
                "the baseline records archives that are no longer present:\n"
                    + comparison.missing.map { "  \($0)" }.joined(separator: "\n")
                    + "\n\nRun your storefront's verify/repair, then"
                    + " archive-loader setup --rebaseline."
            )
        }

        log.step("Restoring \(manifest.archives.count) archives from the baseline...")
        var restored = 0
        _ = try store.restore { _ in restored += 1 }
        try ledger.removeRecorded(
            onRemoved: { log.detail("removed \($0.lastPathComponent)") },
            onSkipped: { log.detail("kept \($0.lastPathComponent) — \($1)") }
        )
        log.info("Restored \(restored) archives")

        let after = try store.compareLive(deep: true)
        guard after.isPristine else {
            throw CLIError.usage(
                "the archives still differ from the baseline after restoring:\n"
                    + after.drifted.map { "  \($0)" }.joined(separator: "\n")
            )
        }

        // Baseline drift is only half of "clean". compareLive knows nothing
        // about generated files, so without this a leftover
        // basegame_99_archive_loader.archive would sit in the game directory
        // while restore reported the install pristine and told the user
        // archive-loader/ was safe to delete — contradicting status, which
        // does run this check.
        let evidence = try NegativeEvidence.inspect(game: game)
        let artifacts = evidence.findings.filter {
            if case .publishedBaseline = $0 { return false }
            return true
        }

        log.info()
        log.info("Restored the recorded archives; they match the baseline.")

        guard artifacts.isEmpty else {
            // Report, but succeed. Restore's contract is to put the recorded
            // archives back, and it did. Now that `patch` records what it
            // generates, anything left here is not ours — most likely a
            // hand-installed basegame_99_ mod, which is documented practice —
            // so a non-zero exit would fail the recovery command for a user
            // who did nothing wrong.
            log.info()
            log.info("These are still present and were left alone:")
            log.info(NegativeEvidence(findings: artifacts).summary)
            log.info()
            log.info("They are not recorded in state/, so this loader will not delete")
            log.info("them. Remove them yourself if they are not yours.")
            // Deliberately no "safe to delete archive-loader/" here: with files
            // outstanding, the install is not back to stock and saying so would
            // be the same false claim this check exists to prevent.
            return
        }

        log.info()
        // The one ordering hazard worth naming: there is no uninstall command,
        // and deleting archive-loader/ before restoring would strand a patched
        // install with its only copy of vanilla inside the deleted directory.
        log.info("archive-loader/ is safe to delete if you want to remove the loader.")

        if !after.unrecorded.isEmpty {
            log.info()
            log.info("Not recorded in the baseline, and left alone:")
            for path in after.unrecorded {
                log.detail(path)
            }
        }
    }
}
