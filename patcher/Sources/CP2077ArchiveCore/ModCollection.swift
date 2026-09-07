import Foundation

/// The enabled mods, in the order that decides which one wins.
///
/// Load order is byte order over the full path. The patcher resolves a
/// contested hash first-wins in ASCII order, matching Windows, and a
/// locale-aware sort weights punctuation loosely enough to reorder the
/// `#`- and `0_`-prefixed names real mod collections use to force position.
/// Getting this wrong changes the winner with no error anywhere, which is why
/// the comparison is explicitly over UTF-8 bytes rather than `String <`.
public enum ModCollection {
    public static func enabledMods(game: GameInstall) throws -> [URL] {
        try enabledMods(in: game.modsEnabledDirectory)
    }

    public static func enabledMods(in directory: URL) throws -> [URL] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return [] }

        guard let enumerator = manager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var mods: [URL] = []
        for case let item as URL in enumerator
        where item.pathExtension == "archive"
            && (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            mods.append(item.normalizedFileURL)
        }

        return mods.sorted { left, right in
            Array(left.path.utf8).lexicographicallyPrecedes(Array(right.path.utf8))
        }
    }
}
