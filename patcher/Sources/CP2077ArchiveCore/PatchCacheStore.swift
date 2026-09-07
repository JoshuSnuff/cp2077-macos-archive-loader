import Darwin
import Foundation

public enum PatchCacheError: Error, CustomStringConvertible {
    case outsideArchiveTree(URL)

    public var description: String {
        switch self {
        case let .outsideArchiveTree(url):
            return "\(url.path) is not inside archive/Mac and cannot be cached"
        }
    }
}

/// One archive held in a cache generation.
public struct CachedArchive: Codable, Sendable, Equatable {
    /// Path relative to `archive/Mac`, e.g. `content/basegame_1_engine.archive`.
    public let path: String
    public let size: UInt64

    public init(path: String, size: UInt64) {
        self.path = path
        self.size = size
    }
}

/// The record of one cached patched image.
public struct CacheManifest: Codable, Sendable, Equatable {
    public let fingerprint: String
    public let builtAt: String
    public let patchFormat: Int
    public let baselineGeneration: String
    public let gameVersion: String
    public let archives: [CachedArchive]
    /// The generated loose archive's path relative to `archive/Mac`, if the
    /// plan produced one. The ledger has to record it after it is cloned back.
    public let looseArchive: String?

    public init(
        fingerprint: String,
        builtAt: String,
        patchFormat: Int,
        baselineGeneration: String,
        gameVersion: String,
        archives: [CachedArchive],
        looseArchive: String?
    ) {
        self.fingerprint = fingerprint
        self.builtAt = builtAt
        self.patchFormat = patchFormat
        self.baselineGeneration = baselineGeneration
        self.gameVersion = gameVersion
        self.archives = archives
        self.looseArchive = looseArchive
    }
}

/// Clones of what a previous run's patch produced.
///
/// Purely an optimization. Nothing in `restore`, `setup`, the negative-evidence
/// gate or the crash-recovery path reads this, and a hit is verified against
/// the plan exactly as a fresh patch is, so the worst a stale or damaged
/// generation can cost is one slow launch.
///
/// Publication mirrors `BaselineStore`: files are cloned into a staging
/// directory, `cache.json` is written last, and the staging directory is
/// renamed into place. A generation is complete or absent, never half-built.
public struct PatchCacheStore: Sendable {
    /// Each generation costs roughly the size of the enabled mod set: its
    /// untouched blocks stay shared with the baseline through `clonefile`, but
    /// the appended payload does not. Two covers the common "toggle one mod
    /// and launch again" case without holding gigabytes for a third.
    public static let retainedGenerations = 2

    public let game: GameInstall

    public init(game: GameInstall) {
        self.game = game
    }

    public func generationDirectory(fingerprint: CacheFingerprint) -> URL {
        game.cacheDirectory.appending(path: fingerprint.value, directoryHint: .isDirectory)
    }

    /// The usable generation for this fingerprint, or nil.
    ///
    /// Every check here is redundant with the fingerprint by construction. They
    /// are cheap and they are what makes a hand-edited or truncated cache a
    /// miss rather than a failed launch.
    public func lookUp(_ fingerprint: CacheFingerprint) throws -> CacheManifest? {
        let generation = generationDirectory(fingerprint: fingerprint)
        let manifestURL = generation.appending(path: "cache.json")
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            if isNotFound(error) { return nil }
            throw error
        }
        guard let manifest = try? JSONDecoder().decode(CacheManifest.self, from: data),
              manifest.fingerprint == fingerprint.value,
              manifest.patchFormat == PatchFormat.current
        else {
            return nil
        }

        let manager = FileManager.default
        for entry in manifest.archives {
            guard (try? validatedLiveArchiveURL(for: entry.path)) != nil else { return nil }
            let file = generation.appending(path: entry.path)
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try manager.attributesOfItem(atPath: file.path)
            } catch {
                if isNotFound(error) { return nil }
                throw error
            }
            guard (attributes[.size] as? NSNumber)?.uint64Value == entry.size else {
                return nil
            }
        }
        if let looseArchive = manifest.looseArchive,
           (try? validatedLiveArchiveURL(for: looseArchive)) == nil {
            return nil
        }
        return manifest
    }

    /// Clones every cached archive over its live counterpart, returning the
    /// live URLs written.
    @discardableResult
    public func apply(_ manifest: CacheManifest, fingerprint: CacheFingerprint) throws -> [URL] {
        let generation = generationDirectory(fingerprint: fingerprint)

        // Validate the complete manifest before cloning anything. A malformed
        // later entry must not leave an earlier live archive overwritten.
        let archives = try manifest.archives.map { entry in
            (
                source: generation.appending(path: entry.path),
                destination: try validatedLiveArchiveURL(for: entry.path)
            )
        }
        if let looseArchive = manifest.looseArchive {
            _ = try validatedLiveArchiveURL(for: looseArchive)
        }

        var written: [URL] = []
        for archive in archives {
            try FileManager.default.createDirectory(
                at: archive.destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Clone.replaceFile(from: archive.source, to: archive.destination)
            written.append(archive.destination.normalizedFileURL)
        }
        return written
    }

    /// Clones the given live archives into a new generation and publishes it.
    @discardableResult
    public func store(
        fingerprint: CacheFingerprint,
        baseline: BaselineManifest,
        patchedArchives: [URL],
        looseArchive: URL?
    ) throws -> CacheManifest {
        let manager = FileManager.default

        // Resolve every future manifest path before the first clone so an
        // invalid later URL cannot leave a partial staging image behind.
        let archives = try patchedArchives
            .map(\.normalizedFileURL)
            .sorted(by: { $0.path < $1.path })
            .map { archive in (archive: archive, path: try relativeArchivePath(archive)) }
        let loosePath = try looseArchive.map { try relativeArchivePath($0.normalizedFileURL) }

        try manager.createDirectory(at: game.cacheDirectory, withIntermediateDirectories: true)

        let staging = game.cacheDirectory
            .appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        let manifest: CacheManifest
        let generation = generationDirectory(fingerprint: fingerprint)
        do {
            var entries: [CachedArchive] = []
            for archive in archives {
                let destination = staging.appending(path: archive.path)
                try manager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Clone.file(from: archive.archive, to: destination)

                let attributes = try manager.attributesOfItem(atPath: destination.path)
                entries.append(CachedArchive(
                    path: archive.path,
                    size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                ))
            }

            manifest = CacheManifest(
                fingerprint: fingerprint.value,
                builtAt: ISO8601DateFormatter().string(from: Date()),
                patchFormat: PatchFormat.current,
                baselineGeneration: baseline.id,
                gameVersion: baseline.gameVersion,
                archives: entries,
                looseArchive: loosePath
            )
            try JSONEncoder.pretty.encode(manifest).write(
                to: staging.appending(path: "cache.json"),
                options: .atomic
            )

            try removeIfPresent(generation, using: manager)
            try manager.moveItem(at: staging, to: generation)
        } catch {
            try? removeIfPresent(staging, using: manager)
            throw error
        }

        try? evict(keeping: generation)
        return manifest
    }

    public func discard(_ fingerprint: CacheFingerprint) throws {
        let manager = FileManager.default
        try removeIfPresent(generationDirectory(fingerprint: fingerprint), using: manager)
    }

    public func clear() throws {
        let manager = FileManager.default
        try removeIfPresent(game.cacheDirectory, using: manager)
    }

    /// Keeps the newest generations and removes everything else, including
    /// staging directories abandoned by an interrupted run.
    private func evict(keeping newest: URL) throws {
        let manager = FileManager.default
        let entries: [URL]
        do {
            entries = try manager.contentsOfDirectory(
                at: game.cacheDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: []
            )
        } catch {
            if isNotFound(error) { return }
            throw error
        }

        var generations: [(url: URL, date: Date)] = []
        for entry in entries {
            if entry.lastPathComponent.hasPrefix(".staging-") {
                try removeIfPresent(entry, using: manager)
                continue
            }
            let date = try entry.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate ?? .distantPast
            generations.append((entry, date))
        }

        let newestPath = newest.standardizedFileURL.path
        let survivors = generations
            .filter { $0.url.standardizedFileURL.path != newestPath }
            .sorted { $0.date > $1.date }
            .prefix(max(0, Self.retainedGenerations - 1))
            .map(\.url.standardizedFileURL.path)
        let keep = Set(survivors + [newestPath])
        for generation in generations where !keep.contains(generation.url.standardizedFileURL.path) {
            try removeIfPresent(generation.url, using: manager)
        }
    }

    private func removeIfPresent(_ url: URL, using manager: FileManager) throws {
        do {
            try manager.removeItem(at: url)
        } catch {
            if isNotFound(error) { return }
            throw error
        }
    }

    private func isNotFound(_ error: Error) -> Bool {
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain,
           cocoa.code == NSFileNoSuchFileError || cocoa.code == NSFileReadNoSuchFileError {
            return true
        }
        if cocoa.domain == NSPOSIXErrorDomain, cocoa.code == ENOENT {
            return true
        }
        if let underlying = cocoa.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.domain == NSPOSIXErrorDomain && underlying.code == ENOENT
        }
        return false
    }

    private func relativeArchivePath(_ archive: URL) throws -> String {
        let root = game.macArchiveDirectory.normalizedFileURL
        let normalizedArchive = archive.normalizedFileURL
        let prefix = root.path + "/"
        guard normalizedArchive.path.hasPrefix(prefix) else {
            throw PatchCacheError.outsideArchiveTree(archive)
        }
        return String(normalizedArchive.path.dropFirst(prefix.count))
    }

    private func validatedLiveArchiveURL(for relativePath: String) throws -> URL {
        let root = game.macArchiveDirectory.normalizedFileURL
        let candidate = root.appending(path: relativePath).normalizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else {
            throw PatchCacheError.outsideArchiveTree(candidate)
        }
        return candidate
    }
}
