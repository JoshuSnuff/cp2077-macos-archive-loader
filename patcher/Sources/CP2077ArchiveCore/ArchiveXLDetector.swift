import Foundation
import Yams

public struct ArchiveXLMatch: Sendable, Equatable {
    /// Absolute path to the manifest or installed plugin marker.
    public let path: String
    /// The enabled tweak document containing a manifest marker, if applicable.
    public let mod: String?
    /// A stable explanation suitable for status/log output.
    public let reason: String

    public init(path: String, mod: String? = nil, reason: String) {
        self.path = path
        self.mod = mod
        self.reason = reason
    }

    public var diagnostic: String {
        if let mod {
            return "[\(ArchiveXLInventory.inventorySchema)] ArchiveXL is required by \(mod) (matched \(path))"
        }
        return "[\(ArchiveXLInventory.inventorySchema)] ArchiveXL plugin marker at \(path)"
    }
}

public struct ArchiveXLInventory: Sendable, Equatable {
    public static let inventorySchema = "archive-loader-archivexl-markers/v1"

    public let schema: String
    public let matches: [ArchiveXLMatch]

    public init(
        schema: String = ArchiveXLInventory.inventorySchema,
        matches: [ArchiveXLMatch]
    ) {
        self.schema = schema
        self.matches = matches
    }

    public var isEmpty: Bool { matches.isEmpty }

    public var diagnostics: [String] { matches.map(\.diagnostic) }
}

/// Conservative, read-only ArchiveXL capability detection.
public enum ArchiveXLDetector {
    public static let inventorySchema = ArchiveXLInventory.inventorySchema

    public static func scan(game: GameInstall) throws -> ArchiveXLInventory {
        try scan(mods: TweakModCollection.mods(game: game), game: game)
    }

    public static func scan(mods: [URL], game: GameInstall) throws -> ArchiveXLInventory {
        var matches: [ArchiveXLMatch] = []
        for mod in mods {
            matches.append(contentsOf: try manifestMatches(in: mod))
        }
        matches.append(contentsOf: try pluginMatches(in: game))
        matches.sort {
            let left = Array($0.path.utf8)
            let right = Array($1.path.utf8)
            if left != right { return left.lexicographicallyPrecedes(right) }
            return ($0.reason, $0.mod ?? "") < ($1.reason, $1.mod ?? "")
        }
        return ArchiveXLInventory(matches: matches)
    }

    private static func manifestMatches(in url: URL) throws -> [ArchiveXLMatch] {
        let contents: String
        do {
            contents = try String(contentsOf: url, encoding: .utf8)
        } catch {
            return []
        }

        guard let root = try? Yams.compose(yaml: contents),
              case let .mapping(mapping) = root else {
            return []
        }

        var matches: [ArchiveXLMatch] = []
        for pair in mapping where pair.key.string == "requires" || pair.key.string == "dependencies" {
            guard let values = exactStringList(pair.value), values.contains("ArchiveXL") else {
                continue
            }
            let field = pair.key.string ?? "metadata"
            matches.append(ArchiveXLMatch(
                path: url.path,
                mod: url.path,
                reason: "root \(field) list contains exact ArchiveXL"
            ))
        }
        return matches
    }

    private static func exactStringList(_ node: Yams.Node) -> [String]? {
        guard case let .sequence(sequence) = node else { return nil }
        return sequence.compactMap { child in
            guard case let .scalar(scalar) = child else { return nil }
            return scalar.string
        }
    }

    private static func pluginMatches(in game: GameInstall) throws -> [ArchiveXLMatch] {
        let root = game.root.appending(path: "red4ext/plugins", directoryHint: .isDirectory)
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { return [] }

        var matches: [ArchiveXLMatch] = []
        let entries = try manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for entry in entries {
            switch entry.lastPathComponent {
            case "ArchiveXL":
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true else { continue }
                matches.append(ArchiveXLMatch(
                    path: entry.normalizedFileURL.path,
                    reason: "installed plugin directory is exactly red4ext/plugins/ArchiveXL/"
                ))
            case "ArchiveXL.dll", "ArchiveXL.dylib":
                matches.append(ArchiveXLMatch(
                    path: entry.normalizedFileURL.path,
                    reason: "installed plugin filename is an exact ArchiveXL v1 marker"
                ))
            default:
                continue
            }
        }
        return matches
    }
}
