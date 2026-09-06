import Foundation

/// Everything on disk that means "something already patched this install".
///
/// This is what establishes trust in a captured baseline; the hashes only
/// preserve it. It does not verify the archives against CDPR's originals —
/// the official archive set is user-dependent, so that cannot be done
/// completely. It establishes that nothing on this machine has patched them,
/// on the grounds that the loader is the only thing on macOS that rewrites
/// these files and every trace it leaves is detectable.
///
/// Inspection is pure. The gate refuses; it never deletes. Refusing on an
/// unrecognised artifact is safe and deleting one is not, so this list must
/// never be reused as a cleanup list.
public struct NegativeEvidence: Sendable {
    public enum Finding: Sendable, Equatable, CustomStringConvertible {
        case looseArchive(URL)
        case modStagingDirectory(URL)
        case legacyBackupDirectory(URL)
        case publishedBaseline(URL)

        public var description: String {
            switch self {
            case let .looseArchive(url):
                return "loose archive \(url.path)"
            case let .modStagingDirectory(url):
                return "mod staging directory \(url.path)"
            case let .legacyBackupDirectory(url):
                return "patcher backup directory \(url.path)"
            case let .publishedBaseline(url):
                return "a baseline is already published at \(url.path)"
            }
        }

        /// What the user should do about it.
        public var remedy: String {
            switch self {
            case .looseArchive:
                return "remove it by hand if it is yours, or run your storefront's verify/repair"
            case .modStagingDirectory:
                return "remove it by hand; archive-loader never creates or deletes this directory"
            case .legacyBackupDirectory:
                return "left by a pre-0.1 session; remove it by hand once you are sure nothing needs it"
            case .publishedBaseline:
                return "use setup --rebaseline to replace it"
            }
        }
    }

    public let findings: [Finding]

    public init(findings: [Finding]) {
        self.findings = findings
    }

    public var isClean: Bool { findings.isEmpty }

    public var summary: String {
        findings.map { "  \($0.description)\n    \($0.remedy)" }.joined(separator: "\n")
    }

    public static func inspect(game: GameInstall) throws -> NegativeEvidence {
        let manager = FileManager.default
        var findings: [Finding] = []

        for directory in [game.macContentArchiveDirectory, game.macEP1ArchiveDirectory] {
            guard manager.fileExists(atPath: directory.path) else { continue }
            let entries = try manager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for entry in entries
            where entry.lastPathComponent.hasPrefix("basegame_99_")
                && entry.pathExtension == "archive" {
                findings.append(.looseArchive(entry.normalizedFileURL))
            }
        }

        if manager.fileExists(atPath: game.modStagingDirectory.path) {
            findings.append(.modStagingDirectory(game.modStagingDirectory.normalizedFileURL))
        }

        for directory in game.legacyPatcherDirectories
        where manager.fileExists(atPath: directory.path) {
            findings.append(.legacyBackupDirectory(directory.normalizedFileURL))
        }

        // A symlink whose target is gone still counts: it is a published
        // generation that something has damaged, and capturing over it would
        // silently discard whatever it pointed at.
        if (try? manager.destinationOfSymbolicLink(atPath: game.pristinePointer.path)) != nil {
            findings.append(.publishedBaseline(game.pristinePointer))
        }

        return NegativeEvidence(
            findings: findings.sorted { $0.description < $1.description }
        )
    }
}
