import Foundation

public struct GameInstall: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var macContentArchiveDirectory: URL {
        root.appending(path: "archive/Mac/content", directoryHint: .isDirectory)
    }

    public var macEP1ArchiveDirectory: URL {
        root.appending(path: "archive/Mac/ep1", directoryHint: .isDirectory)
    }

    /// The single directory the loader owns inside a game installation.
    public var loaderDirectory: URL {
        InstalledLayout.loaderDirectory(inGameRoot: root)
    }

    /// Per-run patcher backups.
    ///
    /// These lived under `archive/Mac/_patcher/backups/` before 0.1. Moving
    /// them out is what lets the negative-evidence gate read anything inside
    /// `archive/Mac/` as somebody else's work, or our own from before 0.1.
    public var backupDirectory: URL {
        loaderDirectory.appending(path: "backups", directoryHint: .isDirectory)
    }

    /// Backup directories written by pre-0.1 sessions, newest naming first.
    ///
    /// Recognised so the gate can refuse on them and an explicit cleanup can
    /// remove them. Never written to.
    public var legacyPatcherDirectories: [URL] {
        [
            root.appending(path: "archive/Mac/_patcher", directoryHint: .isDirectory),
            root.appending(path: "archive/Mac/_cp2077_mac_patcher", directoryHint: .isDirectory),
        ]
    }

    public var managedLooseArchiveDirectory: URL {
        macContentArchiveDirectory
    }

    public var managedLooseArchive: URL {
        managedLooseArchiveDirectory.appending(path: "basegame_99_archive_loader.archive")
    }

    public func macArchives() throws -> [URL] {
        let manager = FileManager.default
        let dirs = [macContentArchiveDirectory, macEP1ArchiveDirectory]
        return try dirs.flatMap { dir -> [URL] in
            guard manager.fileExists(atPath: dir.path) else { return [] }
            return try manager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "archive" }
        }.map(\.normalizedFileURL).sorted { $0.path < $1.path }
    }

    public func officialMacArchives() throws -> [URL] {
        try macArchives().filter { url in
            let name = url.lastPathComponent
            return !name.hasPrefix("basegame_99_")
                && !url.path.contains("/_patcher/")
                && !url.path.contains("/_cp2077_mac_patcher/")
                && !url.path.contains("/_disabled_mod_tests/")
        }
    }

}

public extension URL {
    /// A file URL reduced to one canonical spelling.
    ///
    /// Archive URLs are used as dictionary keys in a `PatchPlan`, and a game
    /// directory reached through a symlink (`/var` vs `/private/var`, or any
    /// user-made link) otherwise yields two unequal URLs for one file.
    var normalizedFileURL: URL {
        resolvingSymlinksInPath().standardizedFileURL
    }
}
