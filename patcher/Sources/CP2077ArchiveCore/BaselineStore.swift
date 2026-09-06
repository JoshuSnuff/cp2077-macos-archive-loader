import Darwin
import Foundation

/// Captured generations of the official archives, and the pointer that says
/// which one is authoritative.
///
/// Publication is a single atomic symlink swap. Cloning files into place and
/// then writing a manifest beside them is not atomic — a crash between the two
/// leaves an unrecorded pristine tree that no recovery path defines — so
/// `capture` and `publish` are separate, and only the second commits.
public struct BaselineStore: Sendable {
    public let game: GameInstall

    public init(game: GameInstall) {
        self.game = game
    }

    public func generationDirectory(id: String) -> URL {
        game.baselinesDirectory.appending(path: id, directoryHint: .isDirectory)
    }

    /// The generation the `pristine` pointer resolves to, or nil.
    public var publishedGeneration: URL? {
        let manager = FileManager.default
        guard let target = try? manager.destinationOfSymbolicLink(atPath: game.pristinePointer.path)
        else {
            return nil
        }
        let resolved = target.hasPrefix("/")
            ? URL(fileURLWithPath: target, isDirectory: true)
            : game.loaderDirectory.appending(path: target, directoryHint: .isDirectory)
        guard manager.fileExists(atPath: resolved.path) else { return nil }
        return resolved
    }

    public func publishedManifest() throws -> BaselineManifest? {
        guard let generation = publishedGeneration else { return nil }
        let manifestURL = generation.appending(path: "baseline.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw BaselineError.unreadableManifest(manifestURL)
        }
        do {
            return try JSONDecoder().decode(BaselineManifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw BaselineError.unreadableManifest(manifestURL)
        }
    }

    /// Clones every official archive into a new generation and records it.
    /// Does not publish: the returned manifest is inert until `publish`.
    ///
    /// `willClone` runs before each file and `didCloneAll` after the last one,
    /// so tests can interrupt at both publication boundaries.
    @discardableResult
    public func capture(
        gameVersion: String,
        storefront: String,
        willClone: (URL) throws -> Void = { _ in },
        didCloneAll: () throws -> Void = {}
    ) throws -> BaselineManifest {
        let manager = FileManager.default
        let archives = try game.officialMacArchives()
        guard !archives.isEmpty else {
            throw BaselineError.noOfficialArchives(game.macContentArchiveDirectory)
        }

        try manager.createDirectory(at: game.baselinesDirectory, withIntermediateDirectories: true)
        let id = try makeGenerationID()
        let generation = generationDirectory(id: id)
        try manager.createDirectory(at: generation, withIntermediateDirectories: false)

        var entries: [BaselineEntry] = []
        for archive in archives {
            try willClone(archive)

            let relativePath = Self.relativeArchivePath(archive)
            let destination = generation.appending(path: relativePath)
            try manager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Clone.file(from: archive, to: destination)

            // Hash the clone, not the original: what the manifest describes is
            // the copy restoration will hand back.
            let attributes = try manager.attributesOfItem(atPath: destination.path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            entries.append(BaselineEntry(
                path: relativePath,
                size: size,
                sha256: try Hashes.sha256Hex(ofFileAt: destination)
            ))
        }

        try didCloneAll()

        let manifest = BaselineManifest(
            id: id,
            capturedAt: ISO8601DateFormatter().string(from: Date()),
            gameVersion: gameVersion,
            storefront: storefront,
            loaderVersion: LoaderVersion.current,
            archives: entries.sorted { $0.path < $1.path }
        )
        try JSONEncoder.pretty.encode(manifest).write(
            to: generation.appending(path: "baseline.json"),
            options: .atomic
        )
        return manifest
    }

    /// The single commit point. Swaps the `pristine` pointer atomically, then
    /// retires generations nothing points at.
    public func publish(_ manifest: BaselineManifest) throws {
        let manager = FileManager.default
        let temporaryPointer = game.loaderDirectory
            .appending(path: ".pristine-\(UUID().uuidString)", directoryHint: .notDirectory)

        // A relative target keeps the pointer valid if the whole game folder
        // is moved or renamed.
        try manager.createSymbolicLink(
            atPath: temporaryPointer.path,
            withDestinationPath: "baselines/\(manifest.id)"
        )
        do {
            try renameAtomically(temporaryPointer, to: game.pristinePointer)
        } catch {
            try? manager.removeItem(at: temporaryPointer)
            throw error
        }

        for entry in (try? manager.contentsOfDirectory(
            atPath: game.baselinesDirectory.path
        )) ?? [] where entry != manifest.id {
            try? manager.removeItem(at: game.baselinesDirectory.appending(path: entry, directoryHint: .isDirectory))
        }
    }

    /// Clones every recorded archive from the published generation back over
    /// the live one. Each file is replaced by rename, so an interrupted
    /// restore leaves whole archives rather than truncated ones.
    @discardableResult
    public func restore(onRestored: (URL) -> Void = { _ in }) throws -> [URL] {
        guard let generation = publishedGeneration, let manifest = try publishedManifest() else {
            throw BaselineError.noPublishedBaseline(game.pristinePointer)
        }

        var restored: [URL] = []
        for entry in manifest.archives {
            let source = generation.appending(path: entry.path)
            let destination = game.root.appending(path: "archive/Mac/\(entry.path)")
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Clone.replaceFile(from: source, to: destination)
            restored.append(destination)
            onRestored(destination)
        }
        return restored
    }

    /// Compares the live archives against the published generation.
    ///
    /// `deep: false` compares sizes only, which is what `status` runs by
    /// default; `deep: true` re-hashes.
    public func compareLive(deep: Bool) throws -> BaselineComparison {
        guard let manifest = try publishedManifest() else {
            throw BaselineError.noPublishedBaseline(game.pristinePointer)
        }
        let manager = FileManager.default

        var matching: [String] = []
        var drifted: [String] = []
        var missing: [String] = []

        for entry in manifest.archives {
            let live = game.root.appending(path: "archive/Mac/\(entry.path)")
            guard manager.fileExists(atPath: live.path) else {
                missing.append(entry.path)
                continue
            }

            let attributes = try manager.attributesOfItem(atPath: live.path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            if size != entry.size {
                drifted.append(entry.path)
            } else if deep, try Hashes.sha256Hex(ofFileAt: live) != entry.sha256 {
                drifted.append(entry.path)
            } else {
                matching.append(entry.path)
            }
        }

        let recorded = Set(manifest.archives.map(\.path))
        let unrecorded = try game.officialMacArchives()
            .map(Self.relativeArchivePath)
            .filter { !recorded.contains($0) }

        return BaselineComparison(
            matching: matching.sorted(),
            drifted: drifted.sorted(),
            missing: missing.sorted(),
            unrecorded: unrecorded.sorted()
        )
    }

    static func relativeArchivePath(_ archive: URL) -> String {
        let parent = archive.deletingLastPathComponent().lastPathComponent
        return "\(parent)/\(archive.lastPathComponent)"
    }

    private func makeGenerationID() throws -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: Date())

        var candidate = stamp
        var attempt = 0
        while FileManager.default.fileExists(atPath: generationDirectory(id: candidate).path) {
            attempt += 1
            candidate = String(format: "%@-%04d", stamp, attempt)
        }
        return candidate
    }

    private func renameAtomically(_ source: URL, to destination: URL) throws {
        let result = source.withUnsafeFileSystemRepresentation { sourcePath -> Int32 in
            guard let sourcePath else { return -1 }
            return destination.withUnsafeFileSystemRepresentation { destinationPath -> Int32 in
                guard let destinationPath else { return -1 }
                return rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw CloneError.failed(source: source, destination: destination, code: errno)
        }
    }
}

/// How the live archives stand against the published generation.
///
/// The three failure categories are deliberately distinct. Drift is
/// recoverable — the recorded bytes are still in the generation. A missing
/// recorded file is not: the baseline can no longer be fully restored. An
/// unrecorded live file is neither, and is usually a language pack installed
/// after capture, so it is reported and never touched.
public struct BaselineComparison: Sendable, Equatable {
    public let matching: [String]
    public let drifted: [String]
    public let missing: [String]
    public let unrecorded: [String]

    public init(matching: [String], drifted: [String], missing: [String], unrecorded: [String]) {
        self.matching = matching
        self.drifted = drifted
        self.missing = missing
        self.unrecorded = unrecorded
    }

    public var isRestorable: Bool { missing.isEmpty }
    public var isPristine: Bool { drifted.isEmpty && missing.isEmpty }
}
