import Foundation

private struct TweakCacheManifest: Codable {
    let fingerprint: String
    let format: Int
    let blobs: [Entry]

    struct Entry: Codable {
        let path: String
        let size: UInt64
        let sha256: String
    }
}

/// Atomic, optional storage for offline-built TweakDB blobs.
public struct TweakCacheStore: Sendable {
    public let game: GameInstall

    public init(game: GameInstall) {
        self.game = game
    }

    public func directory(for fingerprint: CacheFingerprint) -> URL {
        game.tweakCacheRoot.appending(path: fingerprint.value, directoryHint: .isDirectory)
    }

    public func isCurrent(_ fingerprint: CacheFingerprint) -> Bool {
        do {
            return try load(fingerprint) != nil
        } catch {
            return false
        }
    }

    public func installedBlobs(for fingerprint: CacheFingerprint) -> [URL] {
        do {
            return try load(fingerprint) ?? []
        } catch {
            return []
        }
    }

    /// Returns a complete cache generation, or nil for an ordinary cache miss.
    /// Decode and content-integrity failures are cache misses; filesystem
    /// failures still throw so callers can report a cache fallback diagnostic.
    public func load(_ fingerprint: CacheFingerprint) throws -> [URL]? {
        let manifestURL = directory(for: fingerprint).appending(path: "cache.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }

        let manifest: TweakCacheManifest
        do {
            manifest = try JSONDecoder().decode(
                TweakCacheManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch is DecodingError {
            return nil
        }

        guard manifest.fingerprint == fingerprint.value,
              manifest.format == TweakFormat.current,
              !manifest.blobs.isEmpty else { return nil }

        var names = Set<String>()
        var result: [URL] = []
        for entry in manifest.blobs {
            guard game.tweakBlobNames.contains(entry.path),
                  entry.path == URL(fileURLWithPath: entry.path).lastPathComponent,
                  names.insert(entry.path).inserted else { return nil }

            let file = directory(for: fingerprint).appending(path: entry.path)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard (attributes[.size] as? NSNumber)?.uint64Value == entry.size,
                  try Hashes.sha256Hex(ofFileAt: file) == entry.sha256 else { return nil }
            result.append(file)
        }
        return result.sorted { utf8Precedes($0.path, $1.path) }
    }

    public func store(_ built: [URL], for fingerprint: CacheFingerprint) throws {
        let files = try built.map { url -> (source: URL, name: String) in
            let source = url.normalizedFileURL
            let name = source.lastPathComponent
            guard game.tweakBlobNames.contains(name) else {
                throw TweakCacheError.invalidBlobName(name)
            }
            return (source, name)
        }.sorted { utf8Precedes($0.name, $1.name) }

        guard !files.isEmpty else { throw TweakCacheError.emptyGeneration }
        guard Set(files.map { $0.name }).count == files.count else {
            throw TweakCacheError.duplicateBlob
        }

        let manager = FileManager.default
        try manager.createDirectory(at: game.tweakCacheRoot, withIntermediateDirectories: true)
        let staging = game.tweakCacheRoot
            .appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        let destination = directory(for: fingerprint)

        do {
            try manager.createDirectory(at: staging, withIntermediateDirectories: false)
            var entries: [TweakCacheManifest.Entry] = []
            for file in files {
                let target = staging.appending(path: file.name)
                try Clone.file(from: file.source, to: target)
                let attributes = try manager.attributesOfItem(atPath: target.path)
                entries.append(.init(
                    path: file.name,
                    size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                    sha256: try Hashes.sha256Hex(ofFileAt: target)
                ))
            }

            let manifest = TweakCacheManifest(
                fingerprint: fingerprint.value,
                format: TweakFormat.current,
                blobs: entries
            )
            try JSONEncoder.pretty.encode(manifest).write(
                to: staging.appending(path: "cache.json"),
                options: .atomic
            )
            try? manager.removeItem(at: destination)
            try manager.moveItem(at: staging, to: destination)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: game.tweakCacheRoot.path) else { return }
        try FileManager.default.removeItem(at: game.tweakCacheRoot)
    }
}

public enum TweakCacheError: Error, CustomStringConvertible {
    case invalidBlobName(String)
    case duplicateBlob
    case emptyGeneration

    public var description: String {
        switch self {
        case let .invalidBlobName(name):
            return "cannot cache unsupported TweakDB blob \(name)"
        case .duplicateBlob:
            return "cannot cache duplicate TweakDB blobs"
        case .emptyGeneration:
            return "cannot cache an empty TweakDB generation"
        }
    }
}

private func utf8Precedes(_ left: String, _ right: String) -> Bool {
    Array(left.utf8).lexicographicallyPrecedes(Array(right.utf8))
}
