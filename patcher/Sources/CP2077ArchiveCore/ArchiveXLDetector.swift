import Foundation

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
        try scan(requirements: ModFrameworkRequirements.classify(game: game))
    }

    public static func scan(mods: [URL], game: GameInstall) throws -> ArchiveXLInventory {
        try scan(requirements: ModFrameworkRequirements.classify(mods: mods))
    }

    private static func scan(requirements: ModFrameworkRequirements) -> ArchiveXLInventory {
        var matches = requirements.classifications.compactMap { classification -> ArchiveXLMatch? in
            guard classification.requirements.contains(.archiveXL) else { return nil }
            let path = classification.metadata?.path ?? classification.mod.path
            let reason = classification.metadata == nil
                ? "root requires/dependencies list contains exact ArchiveXL"
                : "root requires/dependencies list in \(path) contains exact ArchiveXL"
            return ArchiveXLMatch(path: path, mod: classification.mod.path, reason: reason)
        }
        matches.sort {
            let left = Array($0.path.utf8)
            let right = Array($1.path.utf8)
            if left != right { return left.lexicographicallyPrecedes(right) }
            return ($0.reason, $0.mod ?? "") < ($1.reason, $1.mod ?? "")
        }
        return ArchiveXLInventory(matches: matches)
    }
}
