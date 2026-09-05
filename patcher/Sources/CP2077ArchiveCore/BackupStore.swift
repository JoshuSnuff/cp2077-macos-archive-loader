import Foundation

public struct BackupManifest: Codable, Sendable {
    public let id: String
    public let createdAt: String
    public let targetArchive: String
    public let sourceArchive: String?
    public let originalSize: UInt64
    public let note: String
}

public struct BackupStore: Sendable {
    public let game: GameInstall

    public init(game: GameInstall) {
        self.game = game
    }

    public func createBackup(targetArchive: URL, sourceArchive: URL?, note: String) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: game.backupDirectory, withIntermediateDirectories: true)

        // Claim a directory rather than trusting the id to be unique. A grouped
        // run backs up every target within the same second, and a random suffix
        // collides: the second backup's manifest overwrote the first's, leaving
        // an archive present on disk that no manifest could restore.
        let stamp = Self.timestamp()
        var id = stamp
        var dir = game.backupDirectory.appending(path: id, directoryHint: .isDirectory)
        var attempt = 0
        while true {
            do {
                try manager.createDirectory(at: dir, withIntermediateDirectories: false)
                break
            } catch CocoaError.fileWriteFileExists {
                attempt += 1
                id = "\(stamp)-\(attempt)"
                dir = game.backupDirectory.appending(path: id, directoryHint: .isDirectory)
            }
        }

        let archiveCopy = dir.appending(path: targetArchive.lastPathComponent)
        try manager.copyItem(at: targetArchive, to: archiveCopy)

        let size = try targetArchive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let manifest = BackupManifest(
            id: id,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            targetArchive: targetArchive.path,
            sourceArchive: sourceArchive?.path,
            originalSize: UInt64(size),
            note: note
        )
        let manifestData = try JSONEncoder.pretty.encode(manifest)
        try manifestData.write(to: dir.appending(path: "manifest.json"))
        return dir
    }

    public func restoreLatest() throws -> URL {
        let manager = FileManager.default
        let backups = try manager.contentsOfDirectory(
            at: game.backupDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.hasDirectoryPath }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard let latest = backups.last else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try restore(backupDirectory: latest)
    }

    public func restore(backupDirectory: URL) throws -> URL {
        let manifestURL = backupDirectory.appending(path: "manifest.json")
        let manifest = try JSONDecoder().decode(BackupManifest.self, from: Data(contentsOf: manifestURL))
        let target = URL(fileURLWithPath: manifest.targetArchive)
        let source = backupDirectory.appending(path: target.lastPathComponent)
        let manager = FileManager.default
        if manager.fileExists(atPath: target.path) {
            try manager.removeItem(at: target)
        }
        try manager.copyItem(at: source, to: target)
        return target
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: Date())
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
