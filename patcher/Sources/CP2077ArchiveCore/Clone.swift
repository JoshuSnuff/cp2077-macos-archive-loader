import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum CloneError: Error, CustomStringConvertible {
    case unsupported(URL, Int32)
    case failed(source: URL, destination: URL, code: Int32)

    public var description: String {
        switch self {
        case let .unsupported(url, code):
            return "\(url.path) is on a filesystem without copy-on-write clone support"
                + " (\(String(cString: strerror(code))));"
                + " a full copy of the official archives would cost about 83 GB, so setup refuses"
        case let .failed(source, destination, code):
            return "could not clone \(source.path) to \(destination.path):"
                + " \(String(cString: strerror(code)))"
        }
    }
}

/// APFS copy-on-write cloning.
///
/// Restoring 57 archives before every run is only affordable because a clone
/// costs no time and no disk. Every copy the loader makes of an official
/// archive goes through here.
public enum Clone {
    /// Clones `source` onto `destination`, which must not already exist.
    public static func file(from source: URL, to destination: URL) throws {
        let result = source.withUnsafeFileSystemRepresentation { sourcePath -> Int32 in
            guard let sourcePath else { return -1 }
            return destination.withUnsafeFileSystemRepresentation { destinationPath -> Int32 in
                guard let destinationPath else { return -1 }
                return clonefile(sourcePath, destinationPath, 0)
            }
        }
        guard result == 0 else {
            throw CloneError.failed(source: source, destination: destination, code: errno)
        }
    }

    /// Clones `source` over `destination`, replacing it atomically.
    ///
    /// `clonefile` refuses to overwrite, so this clones to a sibling temporary
    /// and renames over the target. `rename(2)` is atomic, so an interrupted
    /// restore leaves either the old file or the new one — never a truncated
    /// archive that the game would load as corrupt.
    public static func replaceFile(from source: URL, to destination: URL) throws {
        let temporary = destination
            .deletingLastPathComponent()
            .appending(path: ".archive-loader-\(UUID().uuidString).tmp")
        try file(from: source, to: temporary)
        do {
            try rename(temporary, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// Proves the volume supports cloning by performing one, rather than
    /// inferring it from `mount` output. An external volume can report `apfs`
    /// and still refuse `clonefile`.
    public static func verifySupport(in directory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        let probe = directory.appending(path: ".archive-loader-clone-probe-\(UUID().uuidString)")
        let clone = URL(fileURLWithPath: probe.path + ".clone")
        defer {
            try? manager.removeItem(at: probe)
            try? manager.removeItem(at: clone)
        }

        try Data("clone probe".utf8).write(to: probe)
        do {
            try file(from: probe, to: clone)
        } catch let CloneError.failed(_, _, code) {
            throw CloneError.unsupported(directory, code)
        }
    }

    private static func rename(_ source: URL, to destination: URL) throws {
        let result = source.withUnsafeFileSystemRepresentation { sourcePath -> Int32 in
            guard let sourcePath else { return -1 }
            return destination.withUnsafeFileSystemRepresentation { destinationPath -> Int32 in
                guard let destinationPath else { return -1 }
                return Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw CloneError.failed(source: source, destination: destination, code: errno)
        }
    }
}
