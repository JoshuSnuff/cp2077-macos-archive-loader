import CP2077ArchiveCore
import Foundation

enum RestoreCommand {
    static func run(_ args: [String]) throws {
        let options = try Options(args)
        let candidates = try GameDiscovery.resolve(
            explicitRoot: options.value("--game").map { URL(fileURLWithPath: $0, isDirectory: true) }
        )
        guard let candidate = candidates.first, candidates.count == 1 else {
            throw CLIError.usage("could not resolve a single game installation; pass --game")
        }

        let game = GameInstall(root: candidate.root)
        let store = BaselineStore(game: game)
        let ledger = ArtifactLedger(game: game)

        guard !GameProcess.isRunning(game: game) else {
            throw CLIError.usage(
                "Cyberpunk 2077 is running from this installation."
                    + " Quit it first: restoring now would rewrite archives underneath it."
            )
        }

        let lock = try InstallationLock.acquire(game: game)
        defer { lock.release() }

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
            print("warning: the baseline records \(manifest.gameVersion) but the game reports"
                + " \(candidate.version)")
            print("warning: restoring anyway — run `archive-loader setup --rebaseline` afterwards")
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

        print("Restoring \(manifest.archives.count) archives from the baseline...")
        var restored = 0
        _ = try store.restore { _ in restored += 1 }
        try ledger.removeRecorded(
            onRemoved: { print("  removed \($0.lastPathComponent)") },
            onSkipped: { print("  kept \($0.lastPathComponent) — \($1)") }
        )
        print("Restored \(restored) archives")

        let after = try store.compareLive(deep: true)
        guard after.isPristine else {
            throw CLIError.usage(
                "the archives still differ from the baseline after restoring:\n"
                    + after.drifted.map { "  \($0)" }.joined(separator: "\n")
            )
        }

        print("")
        print("This installation matches the recorded baseline.")
        // The one ordering hazard worth naming: there is no uninstall command,
        // and deleting archive-loader/ before restoring would strand a patched
        // install with its only copy of vanilla inside the deleted directory.
        print("archive-loader/ is safe to delete if you want to remove the loader.")

        if !after.unrecorded.isEmpty {
            print("")
            print("Not recorded in the baseline, and left alone:")
            for path in after.unrecorded {
                print("  \(path)")
            }
        }
    }
}
