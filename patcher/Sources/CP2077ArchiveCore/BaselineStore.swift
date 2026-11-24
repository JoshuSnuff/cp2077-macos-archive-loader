import Darwin
import Foundation

public enum BaselineSourceError: Error, CustomStringConvertible {
    case invalidPath(String)
    case unreadable(String)
    case sizeMismatch(String, expected: UInt64, actual: UInt64)
    case checksumMismatch(String, expected: String, actual: String)

    public var description: String {
        switch self {
        case let .invalidPath(path):
            return "baseline source has an invalid path: \(path)"
        case let .unreadable(path):
            return "baseline source is missing or unreadable: \(path)"
        case let .sizeMismatch(path, expected, actual):
            return "baseline source size mismatch for \(path): expected \(expected), got \(actual)"
        case let .checksumMismatch(path, expected, actual):
            return "baseline source SHA-256 mismatch for \(path): expected \(expected), got \(actual)"
        }
    }
}

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
        if let published = try publishedManifest(), published.tweaks.isEmpty,
           let liveBlob = game.tweakBlobs().first {
            throw BaselineError.legacyTweakCapture(liveBlob)
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

        var tweakEntries: [BaselineEntry] = []
        for blob in game.tweakBlobs() {
            let source = try Self.validateTweakURL(blob, game: game)
            try willClone(source)

            let relativePath = Self.relativeTweakPath(blob, game: game)
            let destination = generation.appending(path: relativePath)
            try manager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Clone.file(from: source, to: destination)

            let attributes = try manager.attributesOfItem(atPath: destination.path)
            tweakEntries.append(BaselineEntry(
                path: relativePath,
                size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
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
            archives: entries.sorted { $0.path < $1.path },
            tweaks: tweakEntries.sorted { $0.path < $1.path }
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
        try BaselineManifest.validateTweakEntries(manifest.tweaks)
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

        // Every cache generation is keyed on the baseline id that just stopped
        // being current, so all of them are dead. Doing this here rather than
        // at the three call sites means a new capture path cannot forget it.
        try? PatchCacheStore(game: game).clear()
    }

    /// Clones every recorded archive from the published generation back over
    /// the live one. Each file is replaced by rename, so an interrupted
    /// restore leaves whole archives rather than truncated ones.
    @discardableResult
    public func restore(onRestored: (URL) -> Void = { _ in }) throws -> [URL] {
        guard let generation = publishedGeneration, let manifest = try publishedManifest() else {
            throw BaselineError.noPublishedBaseline(game.pristinePointer)
        }
        try BaselineManifest.validateTweakEntries(manifest.tweaks)
        let archiveSources = try manifest.archives.map { entry in
            try validatedSource(
                generation.appending(path: entry.path),
                generation: generation,
                entry: entry
            )
        }
        let tweakDestinations = try manifest.tweaks.map { entry in
            try Self.validateTweakURL(game.root.appending(path: entry.path), game: game)
        }
        let tweakSources = try manifest.tweaks.map { entry in
            let source = try Self.validateTweakSource(
                generation.appending(path: entry.path), generation: generation, relativePath: entry.path
            )
            return try validatedSource(source, generation: generation, entry: entry)
        }

        var restored: [URL] = []
        for (entry, source) in zip(manifest.archives, archiveSources) {
            let destination = game.root.appending(path: "archive/Mac/\(entry.path)")
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Clone.replaceFile(from: source, to: destination)
            restored.append(destination)
            onRestored(destination)
        }
        for (source, destination) in zip(tweakSources, tweakDestinations) {
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

    private func validatedSource(
        _ url: URL,
        generation: URL,
        entry: BaselineEntry
    ) throws -> URL {
        let root = generation.standardizedFileURL.path
        let lexical = url.standardizedFileURL.path
        guard lexical.hasPrefix(root + "/"),
              url.resolvingSymlinksInPath().standardizedFileURL.path == lexical else {
            throw BaselineSourceError.invalidPath(entry.path)
        }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: lexical)
        } catch {
            throw BaselineSourceError.unreadable(entry.path)
        }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard size == entry.size else {
            throw BaselineSourceError.sizeMismatch(entry.path, expected: entry.size, actual: size)
        }
        let sha256: String
        do {
            sha256 = try Hashes.sha256Hex(ofFileAt: url)
        } catch {
            throw BaselineSourceError.unreadable(entry.path)
        }
        guard sha256 == entry.sha256 else {
            throw BaselineSourceError.checksumMismatch(
                entry.path, expected: entry.sha256, actual: sha256
            )
        }
        return url
    }

    /// The live TweakDB blobs against the published generation. A legacy
    /// archive-only generation intentionally compares as an empty tweak set.
    public func compareLiveTweaks(deep: Bool) throws -> BaselineComparison {
        guard let manifest = try publishedManifest() else {
            throw BaselineError.noPublishedBaseline(game.pristinePointer)
        }
        try BaselineManifest.validateTweakEntries(manifest.tweaks)

        var matching: [String] = []
        var drifted: [String] = []
        var missing: [String] = []
        for entry in manifest.tweaks {
            let live = try Self.validateTweakURL(game.root.appending(path: entry.path), game: game)
            let manager = FileManager.default
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

        return BaselineComparison(
            matching: matching.sorted(),
            drifted: drifted.sorted(),
            missing: missing.sorted(),
            unrecorded: []
        )
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

    public static func relativeTweakPath(_ url: URL, game: GameInstall) -> String {
        let root = game.root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : url.lastPathComponent
    }

    /// Validates both the lexical path and its resolved path. The former
    /// rejects traversal/absolute paths; the latter rejects a symlinked game
    /// subdirectory that would make an allowlisted spelling escape the root.
    public static func validateTweakURL(_ url: URL, game: GameInstall) throws -> URL {
        let root = game.root.standardizedFileURL.path
        let resolvedRoot = game.root.resolvingSymlinksInPath().standardizedFileURL.path
        let lexical = url.standardizedFileURL.path
        guard lexical.hasPrefix(root + "/") else {
            throw BaselineError.invalidTweakPath(relativeTweakPath(url, game: game))
        }
        let relative = String(lexical.dropFirst(root.count + 1))
        guard BaselineManifest.allowedTweakPaths.contains(relative) else {
            throw BaselineError.invalidTweakPath(relative)
        }

        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedRelative = resolvedRoot + "/" + relative
        guard resolved == resolvedRelative else {
            throw BaselineError.invalidTweakPath(relative)
        }
        return url
    }

    private static func validateTweakSource(
        _ url: URL,
        generation: URL,
        relativePath: String
    ) throws -> URL {
        let root = generation.standardizedFileURL.path
        let lexical = url.standardizedFileURL.path
        guard lexical == root + "/" + relativePath else {
            throw BaselineError.invalidTweakPath(relativePath)
        }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved == lexical else {
            throw BaselineError.invalidTweakPath(relativePath)
        }
        return url
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

/// Whether the live files carry enough evidence to recapture a baseline
/// without asking the storefront to verify them again.
public enum RecaptureDecision: Sendable, Equatable {
    case safe(previousGeneration: String)
    case refused(reason: String)
}

public extension BaselineStore {
    /// `run` restores every recorded archive and blob before launch and after
    /// catchable exits. A deep comparison carries that trust into rebaseline;
    /// any drift or missing recorded file requires storefront repair first.
    func canRecaptureFromLive() throws -> RecaptureDecision {
        guard let manifest = try publishedManifest() else {
            return .refused(reason: "no baseline is published yet; run: archive-loader setup")
        }

        let archives = try compareLive(deep: true)
        guard archives.missing.isEmpty else {
            return .refused(
                reason: "\(archives.missing.count) recorded archive(s) are missing from the"
                    + " install; run the storefront's verify/repair, then setup --rebaseline"
            )
        }
        guard archives.drifted.isEmpty else {
            return .refused(
                reason: "\(archives.drifted.count) archive(s) differ from the published"
                    + " generation, so the live set is not known-vanilla; run the storefront's"
                    + " verify/repair, then setup --rebaseline"
            )
        }

        if manifest.tweaks.isEmpty, !game.tweakBlobs().isEmpty {
            return .refused(
                reason: "the published generation is archive-only but live TweakDB blobs exist;"
                    + " verify the installation before rebaseline"
            )
        }

        if !manifest.tweaks.isEmpty {
            let tweaks = try compareLiveTweaks(deep: true)
            guard tweaks.missing.isEmpty else {
                return .refused(
                    reason: "\(tweaks.missing.count) recorded TweakDB blob(s) are missing from"
                        + " the install; run the storefront's verify/repair, then setup --rebaseline"
                )
            }
            guard tweaks.drifted.isEmpty else {
                return .refused(
                    reason: "\(tweaks.drifted.count) TweakDB blob(s) differ from the published"
                        + " generation, so the live set is not known-vanilla; run the storefront's"
                        + " verify/repair, then setup --rebaseline"
                )
            }
        }
        return .safe(previousGeneration: manifest.id)
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
