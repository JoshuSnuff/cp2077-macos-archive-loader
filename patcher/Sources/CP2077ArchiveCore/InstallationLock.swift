import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum InstallationLockError: Error, CustomStringConvertible {
    case held(URL)
    case unopenable(URL, Int32)

    public var description: String {
        switch self {
        case let .held(url):
            return "another archive-loader command is working on this installation"
                + " (lock: \(url.path)). Wait for it to finish, or check for a"
                + " running game before trying again."
        case let .unopenable(url, code):
            return "could not open the installation lock at \(url.path):"
                + " \(String(cString: strerror(code)))"
        }
    }
}

/// The advisory lock every archive- or baseline-mutating command holds.
///
/// `flock(2)` on a descriptor held open for the life of the command, not a
/// lockfile tested for existence: the kernel drops the lock when the holder
/// dies, so a `SIGKILL`ed session cannot wedge every later run. Read-only
/// commands such as `status` deliberately do not take it, so they stay usable
/// for diagnosing a session that is holding one.
public final class InstallationLock {
    public let lockFile: URL

    private var descriptor: Int32
    private var isReleased = false

    private init(lockFile: URL, descriptor: Int32) {
        self.lockFile = lockFile
        self.descriptor = descriptor
    }

    public static func acquire(game: GameInstall) throws -> InstallationLock {
        try FileManager.default.createDirectory(
            at: game.stateDirectory,
            withIntermediateDirectories: true
        )
        let lockFile = game.stateDirectory.appending(path: "lock", directoryHint: .notDirectory)

        let descriptor = lockFile.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        }
        guard descriptor >= 0 else {
            throw InstallationLockError.unopenable(lockFile, errno)
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK {
                throw InstallationLockError.held(lockFile)
            }
            throw InstallationLockError.unopenable(lockFile, code)
        }

        return InstallationLock(lockFile: lockFile, descriptor: descriptor)
    }

    public func release() {
        guard !isReleased else { return }
        isReleased = true
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    deinit {
        release()
    }
}
