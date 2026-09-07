import Foundation

public struct GameInstall: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var macContentArchiveDirectory: URL {
        root.appending(path: "archive/Mac/content", directoryHint: .isDirectory)
    }

    public var macArchiveDirectory: URL {
        root.appending(path: "archive/Mac", directoryHint: .isDirectory)
    }

    public var macEP1ArchiveDirectory: URL {
        root.appending(path: "archive/Mac/ep1", directoryHint: .isDirectory)
    }

    /// The single directory the loader owns inside a game installation.
    public var loaderDirectory: URL {
        InstalledLayout.loaderDirectory(inGameRoot: root)
    }

    /// Captured baseline generations. Each subdirectory is one generation.
    public var baselinesDirectory: URL {
        loaderDirectory.appending(path: "baselines", directoryHint: .isDirectory)
    }

    /// Cloned patched images, one directory per fingerprint.
    ///
    /// Purely an optimization: deleting this directory at any moment is safe and
    /// costs only the time of one more patch.
    public var cacheDirectory: URL {
        loaderDirectory.appending(path: "cache", directoryHint: .isDirectory)
    }

    /// Symlink to the published generation. Switching it is the single commit
    /// point of a capture, which is why it is a link and not a copy.
    ///
    /// Deliberately not hinted as a directory: the path is handed to
    /// `rename(2)` and `symlink(2)`, which want the link itself, not its target.
    public var pristinePointer: URL {
        loaderDirectory.appending(path: "pristine", directoryHint: .notDirectory)
    }

    /// Lock and recorded-artifact state.
    public var stateDirectory: URL {
        loaderDirectory.appending(path: "state", directoryHint: .isDirectory)
    }

    public var logsDirectory: URL {
        loaderDirectory.appending(path: "logs", directoryHint: .isDirectory)
    }

    /// Where the user drops `.archive` mods. Read in place; never copied into
    /// the game's own archive tree.
    public var modsEnabledDirectory: URL {
        loaderDirectory.appending(path: "mods/enabled", directoryHint: .isDirectory)
    }

    /// Windows' mod staging directory. 0.1 never creates it and never deletes
    /// it; its presence is evidence that something else patched this install.
    public var modStagingDirectory: URL {
        root.appending(path: "archive/Mac/mod", directoryHint: .isDirectory)
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
