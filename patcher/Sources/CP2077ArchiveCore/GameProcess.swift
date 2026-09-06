import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Whether this installation's game is running.
///
/// Matching is on the full executable path rather than the process name: a
/// second copy of Cyberpunk 2077 elsewhere on disk is somebody else's session
/// and must not make this one refuse, or be mistaken for it afterwards.
public enum GameProcess {
    /// How long to keep looking for a game the launcher may not have started
    /// yet. `open -a` returns before the application process is observable,
    /// and restoring inside that window would hand the game vanilla archives.
    public static let startupGracePeriod: TimeInterval = 5.0
    public static let pollInterval: TimeInterval = 0.1

    public static func executable(in game: GameInstall) -> URL {
        game.root.appending(path: "Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077")
    }

    public static func isRunning(game: GameInstall) -> Bool {
        !runningPIDs(matching: executable(in: game)).isEmpty
    }

    public static func runningPIDs(matching executable: URL) -> [pid_t] {
        let target = executable.normalizedFileURL.path

        var count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        // Processes can appear between sizing and reading, so ask for room.
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }

        var matches: [pid_t] = []
        var buffer = [CChar](repeating: 0, count: Int(PROC_PIDPATHINFO_SIZE))
        for index in 0..<Int(count) {
            let pid = pids[index]
            guard pid > 0 else { continue }
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { continue }
            let pathBytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
            let path = String(decoding: pathBytes, as: UTF8.self)
            if URL(fileURLWithPath: path).normalizedFileURL.path == target {
                matches.append(pid)
            }
        }
        return matches
    }

    public static func waitForStart(
        matching executable: URL,
        timeout: TimeInterval = startupGracePeriod
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if !runningPIDs(matching: executable).isEmpty { return true }
            Thread.sleep(forTimeInterval: pollInterval)
        } while Date() < deadline
        return !runningPIDs(matching: executable).isEmpty
    }

    @discardableResult
    public static func waitForExit(matching executable: URL) -> TimeInterval {
        let began = Date()
        while !runningPIDs(matching: executable).isEmpty {
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return Date().timeIntervalSince(began)
    }
}

/// Notices the game while the launcher is running.
///
/// After the launcher exits there are two indistinguishable states: the game
/// ran and has already quit, or it never started. A foreground launcher — both
/// upstream ones — produces the first on every ordinary run, so treating them
/// alike would add the whole startup grace period to every launch. This
/// records which one happened.
public final class GameWatcher: @unchecked Sendable {
    private let executable: URL
    private let mutex = NSLock()
    private var seen = false
    private var running = false
    private var thread: Thread?

    public init(executable: URL) {
        self.executable = executable
    }

    public var everSeen: Bool {
        mutex.lock()
        defer { mutex.unlock() }
        return seen
    }

    public func start() {
        mutex.lock()
        running = true
        mutex.unlock()

        let thread = Thread { [weak self] in
            while let self, self.isRunning {
                if !GameProcess.runningPIDs(matching: self.executable).isEmpty {
                    self.markSeen()
                }
                Thread.sleep(forTimeInterval: GameProcess.pollInterval)
            }
        }
        thread.stackSize = 512 * 1024
        thread.start()
        self.thread = thread
    }

    public func stop() {
        mutex.lock()
        running = false
        mutex.unlock()
    }

    private var isRunning: Bool {
        mutex.lock()
        defer { mutex.unlock() }
        return running
    }

    private func markSeen() {
        mutex.lock()
        seen = true
        mutex.unlock()
    }
}
