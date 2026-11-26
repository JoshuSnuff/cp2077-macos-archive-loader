import Foundation

/// Bumped whenever identical inputs can produce different TweakDB bytes.
public enum TweakFormat {
    public static let current = 1
}

public enum TweakFingerprint {
    /// Tweak documents are small enough to hash. Including content as well as
    /// file metadata closes same-size/mtime invalidation holes while preserving
    /// the caller's deterministic mod order.
    public static func compute(
        game: GameInstall,
        manifest: BaselineManifest,
        mods: [URL],
        inventory: ArchiveXLInventory = ArchiveXLInventory(matches: [])
    ) throws -> CacheFingerprint {
        var lines: [String] = [
            "archive-loader-tweak-cache-v1",
            "loaderVersion \(LoaderVersion.current)",
            "tweakFormat \(TweakFormat.current)",
            "gameVersion \(manifest.gameVersion)",
        ]

        for entry in manifest.tweaks.sorted(by: { utf8Precedes($0.path, $1.path) }) {
            lines.append("baseline \(entry.path) \(entry.size) \(entry.sha256)")
        }

        let modsRoot = game.tweakModsDirectory.normalizedFileURL.path + "/"
        for mod in mods {
            let normalized = mod.normalizedFileURL
            let path = normalized.path.hasPrefix(modsRoot)
                ? String(normalized.path.dropFirst(modsRoot.count))
                : normalized.path
            let attributes = try FileManager.default.attributesOfItem(atPath: normalized.path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let modifiedNanoseconds = Int64((modified * 1_000_000_000).rounded())
            let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            let contents = try Hashes.sha256Hex(ofFileAt: normalized)
            lines.append("mod \(path) \(size) \(modifiedNanoseconds) \(inode) \(contents)")
        }

        lines.append("archiveXL.schema \(inventory.schema)")
        for match in inventory.matches.sorted(by: {
            if utf8Precedes($0.path, $1.path) { return true }
            if utf8Precedes($1.path, $0.path) { return false }
            if $0.reason != $1.reason { return $0.reason < $1.reason }
            return ($0.mod ?? "") < ($1.mod ?? "")
        }) {
            lines.append(
                "archiveXL.match " + match.path + " " + (match.mod ?? "") + " " + match.reason
            )
        }

        let canonical = lines.joined(separator: "\n") + "\n"
        return CacheFingerprint(
            value: Hashes.sha256Hex(of: Data(canonical.utf8)),
            canonicalInput: canonical
        )
    }
}

private func utf8Precedes(_ left: String, _ right: String) -> Bool {
    Array(left.utf8).lexicographicallyPrecedes(Array(right.utf8))
}
