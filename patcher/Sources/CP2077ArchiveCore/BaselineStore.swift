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
