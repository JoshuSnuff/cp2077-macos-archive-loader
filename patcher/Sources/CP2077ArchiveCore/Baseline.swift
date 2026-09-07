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

    public init(
        id: String,
        capturedAt: String,
        gameVersion: String,
        storefront: String,
        loaderVersion: String,
        archives: [BaselineEntry]
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.gameVersion = gameVersion
        self.storefront = storefront
        self.loaderVersion = loaderVersion
        self.archives = archives
    }
}

public enum BaselineError: Error, CustomStringConvertible {
    case noPublishedBaseline(URL)
    case unreadableManifest(URL)
    case noOfficialArchives(URL)

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
        }
    }
}
