import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct ArchiveObservation: Sendable {
    public let expected: Set<URL>
    public let samples: [Set<URL>]

    public init(expected: Set<URL>, samples: [Set<URL>]) {
        self.expected = Set(expected.map(\.normalizedFileURL))
        self.samples = samples.map { Set($0.map(\.normalizedFileURL)) }
    }

    public var observed: Set<URL> {
        expected.intersection(samples.reduce(into: Set<URL>()) { $0.formUnion($1) })
    }

    public var notObserved: Set<URL> {
        expected.subtracting(observed)
    }
}

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

    /// Narrows descriptor paths to archive files inside this installation.
    /// Kept deterministic so boundary and set-difference behavior can be
    /// covered without launching the game.
    public static func archiveURLs(paths: [String], under gameRoot: URL) -> Set<URL> {
        let root = gameRoot.normalizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return Set(paths.compactMap { path in
            let url = URL(fileURLWithPath: path).normalizedFileURL
            guard url.path.hasPrefix(prefix), url.path.hasSuffix(".archive") else { return nil }
            return url
        })
    }

    /// Returns nil when libproc cannot inspect the process. That is explicitly
    /// different from a successful sample containing no archive descriptors.
    public static func openArchiveFiles(pid: pid_t, under gameRoot: URL) -> Set<URL>? {
        let byteCount = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard byteCount > 0 else { return nil }

        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](
            repeating: proc_fdinfo(),
            count: Int(byteCount) / stride + 16
        )
        let readCount = descriptors.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard readCount > 0 else { return nil }

        var paths: [String] = []
        for descriptor in descriptors.prefix(Int(readCount) / stride)
        where descriptor.proc_fdtype == PROX_FDTYPE_VNODE {
            var vnode = vnode_fdinfowithpath()
            let vnodeSize = Int32(MemoryLayout<vnode_fdinfowithpath>.stride)
            let result = withUnsafeMutablePointer(to: &vnode) { pointer in
                proc_pidfdinfo(
                    pid,
                    descriptor.proc_fd,
                    PROC_PIDFDVNODEPATHINFO,
                    pointer,
                    vnodeSize
                )
            }
            guard result == vnodeSize else { continue }
            let path = withUnsafePointer(to: &vnode.pvip.vip_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                    String(cString: $0)
                }
            }
            paths.append(path)
        }
        return archiveURLs(paths: paths, under: gameRoot)
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
    private let gameRoot: URL?
    private let expectedArchives: Set<URL>
    private let archiveOpenSampleDelay: TimeInterval
    private let processLookup: (URL) -> [pid_t]
    private let archiveSampler: (pid_t, URL) -> Set<URL>?
    private let mutex = NSLock()
    private var seen = false
    private var startedAt: Date?
    private var firstSeenAt: Date?
    private var running = false
    private var firstSampleAt: Date?
    private var sampleAttempts = 0
    private var archiveSamples: [Set<URL>] = []
    private var thread: Thread?

    public convenience init(
        executable: URL,
        gameRoot: URL? = nil,
        expectedArchives: Set<URL> = [],
        archiveOpenSampleDelay: TimeInterval = 1.0
    ) {
        self.init(
            executable: executable,
            gameRoot: gameRoot,
            expectedArchives: expectedArchives,
            archiveOpenSampleDelay: archiveOpenSampleDelay,
            runningPIDs: GameProcess.runningPIDs(matching:),
            archiveSampler: GameProcess.openArchiveFiles(pid:under:)
        )
    }

    init(
        executable: URL,
        gameRoot: URL?,
        expectedArchives: Set<URL>,
        archiveOpenSampleDelay: TimeInterval,
        runningPIDs: @escaping (URL) -> [pid_t],
        archiveSampler: @escaping (pid_t, URL) -> Set<URL>?
    ) {
        self.executable = executable
        self.gameRoot = gameRoot
        self.expectedArchives = Set(expectedArchives.map(\.normalizedFileURL))
        self.archiveOpenSampleDelay = archiveOpenSampleDelay
        processLookup = runningPIDs
        self.archiveSampler = archiveSampler
    }

    public var everSeen: Bool {
        mutex.lock()
        defer { mutex.unlock() }
        return seen
    }

    public var archiveObservation: ArchiveObservation {
        mutex.lock()
        defer { mutex.unlock() }
        return ArchiveObservation(expected: expectedArchives, samples: archiveSamples)
    }

    /// How long after `start()` the game was first observed running, or nil if it
    /// never was. This is the launcher-to-game interval; the game's own loading
    /// happens after it and is not measured here.
    public var timeToFirstSighting: TimeInterval? {
        mutex.lock()
        defer { mutex.unlock() }
        guard let startedAt, let firstSeenAt else { return nil }
        return firstSeenAt.timeIntervalSince(startedAt)
    }

    public func start() {
        let thread = Thread { [weak self] in
            while let self, self.isRunning {
                let pids = self.processLookup(self.executable)
                if !pids.isEmpty {
                    self.markSeen()
                    self.sampleArchivesIfDue(pids: pids)
                }
                Thread.sleep(forTimeInterval: GameProcess.pollInterval)
            }
        }
        thread.stackSize = 512 * 1024
        mutex.lock()
        running = true
        startedAt = Date()
        self.thread = thread
        mutex.unlock()
        thread.start()
    }

    public func stop() {
        mutex.lock()
        running = false
        let samplingThread = thread
        mutex.unlock()

        // A sampler may still be between descriptor collection and committing
        // its result. Wait without holding the mutex so archiveObservation is
        // final when stop returns. A callback running on this thread must not
        // wait for itself.
        guard let samplingThread, samplingThread !== Thread.current else { return }
        while !samplingThread.isFinished {
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    private var isRunning: Bool {
        mutex.lock()
        defer { mutex.unlock() }
        return running
    }

    private func markSeen() {
        mutex.lock()
        if !seen {
            seen = true
            firstSeenAt = Date()
        }
        mutex.unlock()
    }

    private func sampleArchivesIfDue(pids: [pid_t]) {
        guard let gameRoot, !expectedArchives.isEmpty else { return }

        let now = Date()
        mutex.lock()
        let due: Bool
        if sampleAttempts == 0 {
            firstSampleAt = now
            due = true
        } else if sampleAttempts == 1,
                  let firstSampleAt,
                  now.timeIntervalSince(firstSampleAt) >= archiveOpenSampleDelay {
            due = true
        } else {
            due = false
        }
        if due { sampleAttempts += 1 }
        mutex.unlock()
        guard due else { return }

        var sample = Set<URL>()
        var observedAnyProcess = false
        for pid in pids {
            guard let files = archiveSampler(pid, gameRoot) else { continue }
            observedAnyProcess = true
            sample.formUnion(files)
        }
        guard observedAnyProcess else { return }

        mutex.lock()
        archiveSamples.append(sample)
        mutex.unlock()
    }
}
