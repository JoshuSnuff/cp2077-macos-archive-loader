import Foundation

public struct BackupManifest: Codable, Sendable {
    public let id: String
    public let createdAt: String
    public let targetArchive: String
    public let originalSize: UInt64
    public let note: String
}

public struct ArchiveEntry: Codable, Sendable {
    public let targetArchive: String
    public let directory: String
    public let originalSize: UInt64
}

public struct PlanSummary: Codable, Sendable {
    public let winners: Int
    public let overrides: Int
    public let newResources: Int
    public let conflicts: Int
}

public struct RunManifest: Codable, Sendable {
    public let id: String
    public let createdAt: String
    public let gameRoot: String
    public let mods: [String]
    public var archives: [ArchiveEntry]
    public var completed: Bool
    public let planSummary: PlanSummary
}

public enum BackupStoreError: Error, CustomStringConvertible {
    case incompleteRun(URL)
    case unusableBackup(URL, String)
    case unknownBackupDirectory(URL)

    public var description: String {
        switch self {
        case let .incompleteRun(directory):
            return "backup run \(directory.path) is incomplete; no archives were restored. "
                + "Recover individual archives with --backup <run>/<archive-dir>, or restore from pristine."
        case let .unusableBackup(directory, reason):
            return "backup \(directory.path) is unusable (\(reason)); no archives were restored. "
                + "Recover valid individual archives with --backup <run>/<archive-dir>, or restore from pristine."
        case let .unknownBackupDirectory(directory):
            return "\(directory.path) contains neither run.json nor manifest.json"
        }
    }
}

public struct RunHandle: Sendable {
    public let directory: URL

    private let store: BackupStore

    fileprivate init(directory: URL, store: BackupStore) {
        self.directory = directory
        self.store = store
    }

    @discardableResult
    public func backup(targetArchive: URL, note: String = "before patching") throws -> URL {
        try store.createBackup(targetArchive: targetArchive, in: directory, note: note)
    }

    public func complete() throws {
        var manifest = try store.readRunManifest(at: directory)
        manifest.completed = true
        try store.writeRunManifest(manifest, at: directory)
    }
}

public struct BackupStore: Sendable {
    public let game: GameInstall

    public init(game: GameInstall) {
        self.game = game
    }

    public func beginRun(plan: PatchPlan) throws -> RunHandle {
        let manager = FileManager.default
        try manager.createDirectory(at: game.backupDirectory, withIntermediateDirectories: true)

        let stamp = Self.timestamp()
        var attempt = 0
        var id = stamp
        var directory = game.backupDirectory.appending(path: id, directoryHint: .isDirectory)
        while true {
            do {
                try manager.createDirectory(at: directory, withIntermediateDirectories: false)
                break
            } catch CocoaError.fileWriteFileExists {
                attempt += 1
                id = String(format: "%@-%04d", stamp, attempt)
                directory = game.backupDirectory.appending(path: id, directoryHint: .isDirectory)
            }
        }
        directory = directory.normalizedFileURL

        let manifest = RunManifest(
            id: id,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            gameRoot: game.root.normalizedFileURL.path,
            mods: plan.mods.map(\.normalizedFileURL.path).sorted(),
            archives: [],
            completed: false,
            planSummary: PlanSummary(
                winners: plan.winners.count,
                overrides: plan.overrideCount,
                newResources: plan.newResources.count,
                conflicts: plan.losers.count
            )
        )
        try writeRunManifest(manifest, at: directory)
        return RunHandle(directory: directory, store: self)
    }

    public func restoreLatest(onRestored: (URL) -> Void = { _ in }) throws -> [URL] {
        let runs = try runDirectories()
        guard let latest = runs.last else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try restore(backupDirectory: latest, onRestored: onRestored)
    }

    /// Restores either a complete run or one per-archive backup directory.
    public func restore(
        backupDirectory: URL,
        onRestored: (URL) -> Void = { _ in }
    ) throws -> [URL] {
        let manager = FileManager.default
        if manager.fileExists(atPath: backupDirectory.appending(path: "run.json").path) {
            return try restoreRun(backupDirectory, onRestored: onRestored)
        }
        if manager.fileExists(atPath: backupDirectory.appending(path: "manifest.json").path) {
            let restored = try restoreArchive(backupDirectory)
            onRestored(restored)
            return [restored]
        }
        throw BackupStoreError.unknownBackupDirectory(backupDirectory)
    }

    /// Removes superseded backup runs and returns the directories selected.
    /// In dry-run mode nothing is changed.
    @discardableResult
    public func prune(keep: Int = 3, dryRun: Bool = false) throws -> [URL] {
        let runs = try runDirectories()
        let readable = runs.compactMap { directory -> (URL, RunManifest)? in
            guard let manifest = try? readRunManifest(at: directory) else { return nil }
            return (directory, manifest)
        }
        let completed = readable.filter { $0.1.completed }
        guard let newestCompleted = completed.last else { return [] }

        let retention = max(1, keep)
        let completedToRemove = completed.count > retention
            ? completed.prefix(completed.count - retention).map(\.0)
            : []
        let incompleteToRemove = readable.filter {
            !$0.1.completed && $0.1.id < newestCompleted.1.id
        }.map(\.0)
        let selected = Array(Set(completedToRemove + incompleteToRemove)).sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }

        if !dryRun {
            for directory in selected {
                try FileManager.default.removeItem(at: directory)
            }
        }
        return selected
    }

    fileprivate func createBackup(targetArchive: URL, in runDirectory: URL, note: String) throws -> URL {
        let manager = FileManager.default
        var run = try readRunManifest(at: runDirectory)
        guard !run.completed else {
            throw BackupStoreError.unusableBackup(runDirectory, "run is already complete")
        }

        let size = try Self.fileSize(at: targetArchive)
        let directoryName = targetArchive.lastPathComponent
        let directory = runDirectory.appending(path: directoryName, directoryHint: .isDirectory)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)

        let archiveCopy = directory.appending(path: targetArchive.lastPathComponent)
        try manager.copyItem(at: targetArchive, to: archiveCopy)

        let manifest = BackupManifest(
            id: directoryName,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            targetArchive: targetArchive.normalizedFileURL.path,
            originalSize: size,
            note: note
        )
        try JSONEncoder.pretty.encode(manifest).write(
            to: directory.appending(path: "manifest.json"),
            options: .atomic
        )

        run.archives.append(ArchiveEntry(
            targetArchive: manifest.targetArchive,
            directory: directoryName,
            originalSize: size
        ))
        try writeRunManifest(run, at: runDirectory)
        return directory
    }

    fileprivate func readRunManifest(at directory: URL) throws -> RunManifest {
        try JSONDecoder().decode(
            RunManifest.self,
            from: Data(contentsOf: directory.appending(path: "run.json"))
        )
    }

    fileprivate func writeRunManifest(_ manifest: RunManifest, at directory: URL) throws {
        try JSONEncoder.pretty.encode(manifest).write(
            to: directory.appending(path: "run.json"),
            options: .atomic
        )
    }

    private func restoreRun(_ directory: URL, onRestored: (URL) -> Void) throws -> [URL] {
        let manifest = try readRunManifest(at: directory)
        guard manifest.completed else {
            throw BackupStoreError.incompleteRun(directory)
        }

        // Validate the whole set before touching any target. Filesystems cannot
        // make the subsequent copies atomic, but a partial or corrupt set must
        // never produce a partial restore by construction.
        let archives = try manifest.archives.map { entry -> (source: URL, target: URL) in
            guard Self.isSafeRelativeComponent(entry.directory) else {
                throw BackupStoreError.unusableBackup(directory, "invalid archive directory \(entry.directory)")
            }
            let archiveDirectory = directory.appending(path: entry.directory, directoryHint: .isDirectory)
            let target = URL(fileURLWithPath: entry.targetArchive)
            let source = archiveDirectory.appending(path: target.lastPathComponent)
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw BackupStoreError.unusableBackup(archiveDirectory, "backup file is missing")
            }
            let size = try Self.fileSize(at: source)
            guard size == entry.originalSize else {
                throw BackupStoreError.unusableBackup(
                    archiveDirectory,
                    "expected \(entry.originalSize) bytes, found \(size)"
                )
            }
            return (source, target)
        }

        return try archives.map {
            let restored = try restoreCopy(from: $0.source, to: $0.target)
            onRestored(restored)
            return restored
        }
    }

    private func restoreArchive(_ directory: URL) throws -> URL {
        let manifestURL = directory.appending(path: "manifest.json")
        let manifest = try JSONDecoder().decode(BackupManifest.self, from: Data(contentsOf: manifestURL))
        let target = URL(fileURLWithPath: manifest.targetArchive)
        let source = directory.appending(path: target.lastPathComponent)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw BackupStoreError.unusableBackup(directory, "backup file is missing")
        }
        let size = try Self.fileSize(at: source)
        guard size == manifest.originalSize else {
            throw BackupStoreError.unusableBackup(
                directory,
                "expected \(manifest.originalSize) bytes, found \(size)"
            )
        }
        return try restoreCopy(from: source, to: target)
    }

    private func restoreCopy(from source: URL, to target: URL) throws -> URL {
        let manager = FileManager.default
        if manager.fileExists(atPath: target.path) {
            try manager.removeItem(at: target)
        }
        try manager.copyItem(at: source, to: target)
        return target
    }

    private func runDirectories() throws -> [URL] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: game.backupDirectory.path) else { return [] }
        return try manager.contentsOfDirectory(
            at: game.backupDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter {
            $0.hasDirectoryPath && manager.fileExists(atPath: $0.appending(path: "run.json").path)
        }.map {
            // Preserve the caller's spelling of the game root (`/var` versus
            // `/private/var`) so handles returned by beginRun compare equal to
            // the same runs returned by restore/prune enumeration.
            game.backupDirectory.appending(path: $0.lastPathComponent, directoryHint: .isDirectory)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func fileSize(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attributes[.size] as? NSNumber else {
            throw BackupStoreError.unusableBackup(url, "could not determine file size")
        }
        return number.uint64Value
    }

    private static func isSafeRelativeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/")
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
