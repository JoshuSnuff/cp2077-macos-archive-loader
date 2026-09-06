import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Where the loader lives inside a game installation, and how it finds that
/// installation from its own position on disk.
///
/// An installed binary sits at `<game>/archive-loader/bin/archive-loader`, so
/// the game root is two directories above the one holding the executable. A
/// development build sits somewhere else entirely; `gameRoot(forExecutable:)`
/// still returns a URL for it, and callers are expected to validate that URL
/// and fall through when it is not a game.
public enum InstalledLayout {
    /// The single top-level directory the release owns inside a game install.
    public static let directoryName = "archive-loader"

    /// Absolute path of the running executable, symlinks resolved, or nil when
    /// the kernel will not report one.
    ///
    /// `CommandLine.arguments[0]` cannot be used for this: it is whatever the
    /// caller typed, which may be a bare name found on `PATH` or a relative
    /// path against a working directory that has since changed.
    public static func currentExecutable() -> URL? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }

        let pathBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let path = String(decoding: pathBytes, as: UTF8.self)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).normalizedFileURL
    }

    /// The game root implied by an executable installed at
    /// `<game>/archive-loader/bin/archive-loader`.
    public static func gameRoot(forExecutable executable: URL) -> URL {
        executable.normalizedFileURL
            .deletingLastPathComponent()  // .../archive-loader/bin
            .deletingLastPathComponent()  // .../archive-loader
            .deletingLastPathComponent()  // the game root
            .standardizedFileURL
    }

    /// The loader's own directory inside a game installation.
    public static func loaderDirectory(inGameRoot root: URL) -> URL {
        root.appending(path: directoryName, directoryHint: .isDirectory)
    }
}
