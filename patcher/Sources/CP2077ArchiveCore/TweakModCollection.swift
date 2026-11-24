import Foundation

/// Supported tweak documents in deterministic UTF-8 byte order.
public enum TweakModCollection {
    public static let supportedExtensions: Set<String> = ["yaml", "yml", "tweak"]

    public static func mods(game: GameInstall) throws -> [URL] {
        try mods(in: game.tweakModsDirectory)
    }

    public static func mods(in directory: URL) throws -> [URL] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return [] }
        guard let enumerator = manager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var found: [URL] = []
        for case let item as URL in enumerator {
            guard supportedExtensions.contains(item.pathExtension),
                  (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            found.append(item.standardizedFileURL)
        }

        return found.sorted { left, right in
            Array(left.path.utf8).lexicographicallyPrecedes(Array(right.path.utf8))
        }
    }
}
