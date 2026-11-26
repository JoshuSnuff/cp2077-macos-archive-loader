import Foundation

/// Supported tweak documents in deterministic UTF-8 byte order.
public enum TweakModCollection {
    public static let supportedExtensions: Set<String> = ["yaml", "yml", "tweak"]
    public static let frameworkExtensions: Set<String> = ["yaml", "yml", "tweak", "xl", "archive"]

    public static func mods(game: GameInstall) throws -> [URL] {
        try mods(in: game.tweakModsDirectory)
    }

    public static func mods(in directory: URL) throws -> [URL] {
        try files(in: directory, extensions: supportedExtensions, caseInsensitive: false)
    }

    /// Recursively discovers every supported mod payload for framework
    /// classification. `mods(in:)` remains text-only for the offline builder.
    public static func frameworkMods(in directory: URL) throws -> [URL] {
        try files(in: directory, extensions: frameworkExtensions, caseInsensitive: true)
    }

    public static func frameworkMods(game: GameInstall) throws -> [URL] {
        let tweakMods = try frameworkMods(in: game.tweakModsDirectory)
        let archiveMods = try frameworkMods(in: game.modsEnabledDirectory)
        var seen = Set<URL>()
        return (tweakMods + archiveMods)
            .map(\.standardizedFileURL)
            .filter { seen.insert($0).inserted }
            .sorted { utf8Precedes($0.path, $1.path) }
    }

    public static func frameworkSources(game: GameInstall) throws -> [ModFrameworkSource] {
        let tweakSources = try files(
            in: game.tweakModsDirectory,
            extensions: frameworkExtensions,
            caseInsensitive: true,
            includeSymlinks: true
        ).map {
            ModFrameworkSource(
                url: $0,
                root: game.tweakModsDirectory.standardizedFileURL,
                role: .tweakDocument
            )
        }
        let archiveSources = try files(
            in: game.modsEnabledDirectory,
            extensions: frameworkExtensions,
            caseInsensitive: true,
            includeSymlinks: true
        ).map {
            ModFrameworkSource(
                url: $0,
                root: game.modsEnabledDirectory.standardizedFileURL,
                role: .archivePayload
            )
        }
        return (tweakSources + archiveSources).sorted {
            utf8Precedes($0.url.path, $1.url.path)
        }
    }

    private static func files(
        in directory: URL,
        extensions: Set<String>,
        caseInsensitive: Bool,
        includeSymlinks: Bool = false
    ) throws -> [URL] {
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
            let extensionName = caseInsensitive
                ? item.pathExtension.lowercased()
                : item.pathExtension
            guard extensions.contains(extensionName) else { continue }
            let values = try? item.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values?.isRegularFile == true
                || (includeSymlinks && values?.isSymbolicLink == true)
            else { continue }
            found.append(item.standardizedFileURL)
        }

        return found.sorted { left, right in
            Array(left.path.utf8).lexicographicallyPrecedes(Array(right.path.utf8))
        }
    }
}

private func utf8Precedes(_ left: String, _ right: String) -> Bool {
    Array(left.utf8).lexicographicallyPrecedes(Array(right.utf8))
}
