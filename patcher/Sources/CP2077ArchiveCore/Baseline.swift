import Foundation

/// One official archive as it stood at capture time.
public struct BaselineEntry: Codable, Sendable, Equatable {
    /// Path relative to `archive/Mac`, e.g. `content/basegame_1_engine.archive`.
    public let path: String
    public let size: UInt64
    /// Lowercase hex SHA-256.
    public let sha256: String

    public init(path: String, size: UInt64, sha256: String) {
        self.path = path
        self.size = size
        self.sha256 = sha256
    }
}

/// The record of one captured generation.
///
/// `gameVersion` is what makes a rebaseline after a game update take the
/// changed-version path rather than restoring the old build's archives over
/// the new install.
public struct BaselineManifest: Codable, Sendable, Equatable {
    public let id: String
    public let capturedAt: String
    public let gameVersion: String
    public let storefront: String
    public let loaderVersion: String
    public let archives: [BaselineEntry]
    /// TweakDB blobs relative to the game root, rather than archive/Mac.
    /// Older generations omit this key and decode as archive-only baselines.
    public let tweaks: [BaselineEntry]

    public init(
        id: String,
        capturedAt: String,
        gameVersion: String,
        storefront: String,
        loaderVersion: String,
        archives: [BaselineEntry],
        tweaks: [BaselineEntry] = []
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.gameVersion = gameVersion
        self.storefront = storefront
        self.loaderVersion = loaderVersion
        self.archives = archives
        self.tweaks = tweaks
    }

    private enum CodingKeys: String, CodingKey {
        case id, capturedAt, gameVersion, storefront, loaderVersion, archives, tweaks
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        capturedAt = try container.decode(String.self, forKey: .capturedAt)
        gameVersion = try container.decode(String.self, forKey: .gameVersion)
        storefront = try container.decode(String.self, forKey: .storefront)
        loaderVersion = try container.decode(String.self, forKey: .loaderVersion)
        archives = try container.decode([BaselineEntry].self, forKey: .archives)
        tweaks = try container.decodeIfPresent([BaselineEntry].self, forKey: .tweaks) ?? []
        try Self.validateTweakEntries(tweaks)
    }

    /// The only paths a baseline may ever carry for the gameplay database.
    public static let allowedTweakPaths: Set<String> = [
        "r6/cache/tweakdb.bin",
        "r6/cache/tweakdb_ep1.bin",
    ]

    public static func validateTweakEntries(_ entries: [BaselineEntry]) throws {
        var seen = Set<String>()
        for entry in entries {
            guard allowedTweakPaths.contains(entry.path), seen.insert(entry.path).inserted else {
                throw BaselineError.invalidTweakPath(entry.path)
            }
        }
    }
}

public enum BaselineError: Error, CustomStringConvertible {
    case noPublishedBaseline(URL)
    case unreadableManifest(URL)
    case noOfficialArchives(URL)
    case invalidTweakPath(String)
    case legacyTweakCapture(URL)

    public var description: String {
        switch self {
        case let .noPublishedBaseline(url):
            return "no baseline has been captured for this installation"
                + " (expected \(url.path)). Run: archive-loader setup"
        case let .unreadableManifest(url):
            return "the baseline manifest at \(url.path) could not be read."
                + " Run: archive-loader setup --rebaseline"
        case let .noOfficialArchives(url):
            return "found no official archives under \(url.path);"
                + " this does not look like a Cyberpunk 2077 installation"
        case let .invalidTweakPath(path):
            return "baseline contains an invalid TweakDB path \(path);"
                + " only r6/cache/tweakdb.bin and r6/cache/tweakdb_ep1.bin are allowed"
        case let .legacyTweakCapture(url):
            return "cannot capture live TweakDB blob \(url.path) into a legacy archive-only baseline"
        }
    }
}
