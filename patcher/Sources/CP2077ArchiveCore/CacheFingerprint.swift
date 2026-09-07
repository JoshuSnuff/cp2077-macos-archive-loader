import Darwin
import Foundation

public enum CacheFingerprintError: Error, CustomStringConvertible {
    case unreadable(URL)

    public var description: String {
        switch self {
        case let .unreadable(url):
            return "could not stat \(url.path) while fingerprinting the patch cache"
        }
    }
}

/// Everything that decides what a patched install looks like, reduced to one
/// hash.
///
/// This is a performance input, never a correctness one: it decides whether a
/// run writes bytes, and `PlanVerifier` still checks the result either way. A
/// missed invalidation therefore costs a failed verification and one slow
/// retry, not a wrong install.
public struct CacheFingerprint: Sendable, Equatable {
    /// Lowercase hex SHA-256 of `canonicalInput`.
    public let value: String
    /// The exact bytes hashed. Logged in debug mode so a surprising miss can
    /// be diffed against the previous session rather than guessed at.
    public let canonicalInput: String

    public static func compute(
        game: GameInstall,
        manifest: BaselineManifest,
        officialArchives: [URL],
        mods: [URL]
    ) throws -> CacheFingerprint {
        var lines: [String] = [
            "archive-loader-cache-v2",
            "patchFormat \(PatchFormat.current)",
            "baseline \(manifest.id)",
            "gameVersion \(manifest.gameVersion)",
        ]

        // The live set, not the manifest's: a language pack installed after
        // capture changes the plan and leaves the baseline id untouched.
        // Recorded archives reuse the digest of the baseline clone just
        // restored by `run`; only post-baseline archives need to be read here.
        let baselineArchives = Dictionary(uniqueKeysWithValues: manifest.archives.map {
            ($0.path, $0.sha256)
        })
        for archive in officialArchives.map(\.normalizedFileURL).sorted(by: { $0.path < $1.path }) {
            let identity = try identity(of: archive)
            let path = BaselineStore.relativeArchivePath(archive)
            let sha256 = try baselineArchives[path] ?? Hashes.sha256Hex(ofFileAt: archive)
            lines.append("official \(path) \(identity.size) \(sha256)")
        }

        // In ModCollection order: the order is what decides a contested hash,
        // so a rename that reorders two mods must not hash the same.
        let modsRoot = game.modsEnabledDirectory.normalizedFileURL.path + "/"
        for mod in mods {
            let identity = try identity(of: mod)
            let path = mod.path.hasPrefix(modsRoot)
                ? String(mod.path.dropFirst(modsRoot.count))
                : mod.path
            lines.append(
                "mod \(path) \(identity.size) \(identity.mtimeNanoseconds) \(identity.inode)"
            )
        }

        let canonical = lines.joined(separator: "\n") + "\n"
        return CacheFingerprint(
            value: Hashes.sha256Hex(of: Data(canonical.utf8)),
            canonicalInput: canonical
        )
    }

    /// Size, whole-nanosecond mtime and inode.
    ///
    /// Deliberately not a content hash: the enabled mod set runs to gigabytes,
    /// and hashing it would consume most of what the cache saves. The hole is
    /// a mod rewritten in place at an identical size with its mtime preserved;
    /// `run --no-cache` and `cache clear` are the documented ways out.
    private static func identity(of url: URL) throws -> (size: UInt64, mtimeNanoseconds: Int64, inode: UInt64) {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return stat(path, &info)
        }
        guard result == 0 else { throw CacheFingerprintError.unreadable(url) }
        let nanoseconds = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000
            + Int64(info.st_mtimespec.tv_nsec)
        return (UInt64(info.st_size), nanoseconds, UInt64(info.st_ino))
    }
}
