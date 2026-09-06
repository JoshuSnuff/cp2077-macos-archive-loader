import Foundation

private enum ArtifactLedgerError: Error {
    case artifactOutsideGameRoot(URL)
}

public struct ArtifactRecord: Codable, Sendable, Equatable {
    /// Path relative to the game root, so an install that gets moved or
    /// renamed still cleans up after itself.
    public let path: String
    public let sha256: String

    public init(path: String, sha256: String) {
        self.path = path
        self.sha256 = sha256
    }
}

public struct RecordedArtifacts: Codable, Sendable, Equatable {
    public let recordedAt: String
    public let artifacts: [ArtifactRecord]

    public init(recordedAt: String, artifacts: [ArtifactRecord]) {
        self.recordedAt = recordedAt
        self.artifacts = artifacts
    }
}

/// What this loader generated, so cleanup can delete that and nothing else.
///
/// Deliberately separate from `NegativeEvidence`. That list is what makes
/// setup refuse; this one is what makes cleanup delete. Refusing on an
/// unrecognised artifact is safe and deleting one is not, so a single shared
/// list would eventually sweep a user's hand-installed `basegame_99_` mod —
/// which is the documented way to add new content by hand.
public struct ArtifactLedger: Sendable {
    public let game: GameInstall

    public init(game: GameInstall) {
        self.game = game
    }

    public var ledgerFile: URL {
        game.stateDirectory.appending(path: "artifacts.json", directoryHint: .notDirectory)
    }

    public func record(_ urls: [URL]) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: game.stateDirectory, withIntermediateDirectories: true)

        let artifacts = try urls.compactMap { url -> ArtifactRecord? in
            guard manager.fileExists(atPath: url.path) else { return nil }
            return ArtifactRecord(
                path: try relativePath(of: url),
                sha256: try Hashes.sha256Hex(ofFileAt: url)
            )
        }

        let recorded = RecordedArtifacts(
            recordedAt: ISO8601DateFormatter().string(from: Date()),
            artifacts: artifacts
        )
        try JSONEncoder.pretty.encode(recorded).write(to: ledgerFile, options: .atomic)
    }

    public func recorded() throws -> RecordedArtifacts? {
        guard FileManager.default.fileExists(atPath: ledgerFile.path) else { return nil }
        return try JSONDecoder().decode(RecordedArtifacts.self, from: Data(contentsOf: ledgerFile))
    }

    /// Deletes every recorded artifact whose bytes still match what was
    /// recorded, then empties the ledger.
    ///
    /// A recorded path whose contents changed is skipped: whatever is there
    /// now is not the file we wrote, and we do not delete files we cannot
    /// account for.
    @discardableResult
    public func removeRecorded(
        onRemoved: (URL) -> Void = { _ in },
        onSkipped: (URL, String) -> Void = { _, _ in }
    ) throws -> [URL] {
        guard let recorded = try recorded() else { return [] }
        let manager = FileManager.default

        var removed: [URL] = []
        for artifact in recorded.artifacts {
            guard let url = recordedURL(for: artifact.path) else {
                let attemptedURL = game.root.appending(path: artifact.path)
                onSkipped(attemptedURL, "path is outside the game root")
                continue
            }
            guard manager.fileExists(atPath: url.path) else { continue }

            let current = try Hashes.sha256Hex(ofFileAt: url)
            guard current == artifact.sha256 else {
                onSkipped(url, "contents changed since it was recorded")
                continue
            }

            try manager.removeItem(at: url)
            removed.append(url)
            onRemoved(url)
        }

        try clear()
        return removed
    }

    private func recordedURL(for path: String) -> URL? {
        guard !path.isEmpty, !path.hasPrefix("/") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(".."), !components.contains(".") else { return nil }

        let root = game.root.normalizedFileURL
        let url = root.appending(path: path, directoryHint: .notDirectory).normalizedFileURL
        let rootPath = root.path
        let descendantPrefix = rootPath == "/" ? "/" : rootPath + "/"
        guard url.path.hasPrefix(descendantPrefix) else { return nil }
        return url
    }

    public func clear() throws {
        try JSONEncoder.pretty
            .encode(RecordedArtifacts(
                recordedAt: ISO8601DateFormatter().string(from: Date()),
                artifacts: []
            ))
            .write(to: ledgerFile, options: .atomic)
    }

    private func relativePath(of url: URL) throws -> String {
        let root = game.root.normalizedFileURL.path
        let path = url.normalizedFileURL.path
        guard path.hasPrefix(root + "/") else {
            throw ArtifactLedgerError.artifactOutsideGameRoot(url)
        }
        return String(path.dropFirst(root.count + 1))
    }
}
