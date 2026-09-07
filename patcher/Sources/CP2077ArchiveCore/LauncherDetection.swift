import Foundation

public struct DetectedLauncher: Sendable, Equatable {
    public let url: URL
    /// True for a name a known upstream project ships.
    public let isKnownName: Bool

    public init(url: URL, isKnownName: Bool) {
        self.url = url
        self.isKnownName = isKnownName
    }
}

/// Finds the launcher script the user already runs.
///
/// The loader wraps it rather than editing or replacing it. Both known names
/// belong to other projects — `launch_modded.sh` to
/// `cyberpunk2077-input-loader-mac`, `launch_red4ext.sh` to `RED4ext-macos` —
/// and a user running both has hand-merged them into something that differs on
/// every machine. Nothing here parses the file, because nothing needs to.
public enum LauncherDetection {
    public static let knownNames = ["launch_modded.sh", "launch_red4ext.sh"]

    public static func detect(game: GameInstall) throws -> [DetectedLauncher] {
        let manager = FileManager.default
        // Shallow: the game root only. archive-loader/ is ours, and descending
        // into the app bundle would find scripts nobody launches the game with.
        let entries = (try? manager.contentsOfDirectory(
            at: game.root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []

        // `.command` counts because Finder runs those on a double-click, so a
        // user who wanted a clickable launcher would have named it that way —
        // and it is what this release names its own installer.
        let scriptExtensions: Set<String> = ["sh", "command"]
        let ourOwnFiles: Set<String> = ["setup.sh", "setup.command"]

        let executableScripts = entries.filter { url in
            scriptExtensions.contains(url.pathExtension)
                && !ourOwnFiles.contains(url.lastPathComponent)
                && manager.isExecutableFile(atPath: url.path)
                && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.map(\.normalizedFileURL)

        var results: [DetectedLauncher] = []
        for name in knownNames {
            if let match = executableScripts.first(where: { $0.lastPathComponent == name }) {
                results.append(DetectedLauncher(url: match, isKnownName: true))
            }
        }
        let remaining = executableScripts
            .filter { !knownNames.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        results.append(contentsOf: remaining.map { DetectedLauncher(url: $0, isKnownName: false) })
        return results
    }

    /// The exact command to run, relative to the game directory.
    ///
    /// The target is not always a script in the game root: with no launcher at
    /// all, `setup` points this at the game binary, which lives several levels
    /// down inside the app bundle. Using just the last path component would
    /// print `./Cyberpunk2077` and send the user to a file that is not there.
    public static func runCommand(for launcher: URL, game: GameInstall) -> String {
        let loaderBinary = "./\(InstalledLayout.directoryName)/bin/\(InstalledLayout.directoryName)"
        return "\(quote(loaderBinary)) run -- \(quote("./\(relativePath(of: launcher, in: game))"))"
    }

    /// `launcher` expressed relative to the game root, falling back to the
    /// absolute path when it lies outside.
    static func relativePath(of launcher: URL, in game: GameInstall) -> String {
        let root = game.root.normalizedFileURL.path
        let path = launcher.normalizedFileURL.path
        guard path.hasPrefix(root + "/") else { return path }
        return String(path.dropFirst(root.count + 1))
    }

    private static func quote(_ value: String) -> String {
        // Normal installs put the game somewhere with a space in the path, but
        // these two are relative to it, so quoting is only needed when the
        // script's own name carries one.
        guard value.contains(where: { $0 == " " || $0 == "'" }) else { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
