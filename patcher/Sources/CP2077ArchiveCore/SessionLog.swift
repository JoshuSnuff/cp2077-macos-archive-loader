import Darwin
import Foundation

/// How long one phase of a session took.
public struct PhaseTiming: Sendable, Equatable {
    public let phase: String
    public let seconds: Double
}

/// One durable record of a user-facing loader command.
///
/// Terminal output and its text-log counterpart share this one path so a fact
/// cannot reach one sink without reaching the other. Text lines are written
/// and fsync'ed before the call returns because several recovery paths use
/// `exit(3)`, which does not unwind deferred cleanup.
public final class SessionLog {
    public let textLogURL: URL
    public let debugLogURL: URL?

    private let textDescriptor: Int32
    private let debugDescriptor: Int32?
    private let standardOutput: FileHandle
    private let standardError: FileHandle
    private let mutex = NSLock()
    private var stepNumber = 0
    private var phaseTimings: [PhaseTiming] = []

    public init(
        command: String,
        logsDirectory: URL,
        debug: Bool = false,
        date: Date = Date(),
        standardOutput: FileHandle = .standardOutput,
        standardError: FileHandle = .standardError,
        retentionLimit: Int = 20
    ) throws {
        precondition(["run", "setup", "restore"].contains(command))
        precondition(retentionLimit > 0)

        self.standardOutput = standardOutput
        self.standardError = standardError

        let manager = FileManager.default
        try manager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        let allocationLock = try Self.acquireAllocationLock(in: logsDirectory)
        defer {
            _ = flock(allocationLock, LOCK_UN)
            close(allocationLock)
        }
        try Self.prune(logsDirectory: logsDirectory, keepingExisting: retentionLimit - 1)

        let reservation = try Self.reserveTextLog(
            command: command,
            startingAt: date,
            logsDirectory: logsDirectory
        )
        textLogURL = reservation.url
        debugLogURL = debug ? logsDirectory.appending(path: "\(reservation.session).jsonl") : nil

        textDescriptor = reservation.descriptor
        do {
            if let debugLogURL {
                debugDescriptor = try Self.openNewFile(debugLogURL)
            } else {
                debugDescriptor = nil
            }
            try Self.publishLatest(textLogURL, in: logsDirectory)
        } catch {
            close(textDescriptor)
            try? manager.removeItem(at: textLogURL)
            if let debugLogURL {
                try? manager.removeItem(at: debugLogURL)
            }
            throw error
        }
    }

    deinit {
        close(textDescriptor)
        if let debugDescriptor {
            close(debugDescriptor)
        }
    }

    public func step(_ message: String) {
        mutex.lock()
        stepNumber += 1
        emitLocked("\(stepNumber). \(message)", level: "step", terminal: standardOutput)
        mutex.unlock()
    }

    public func detail(_ message: String) {
        emit("  \(message)", level: "detail", terminal: standardOutput)
    }

    public func info(_ message: String = "") {
        emit(message, level: "info", terminal: standardOutput)
    }

    public func note(_ message: String) {
        emit("note: \(message)", level: "note", terminal: standardError)
    }

    public func warning(_ message: String) {
        emit("warning: \(message)", level: "warning", terminal: standardError)
    }

    public func failure(_ message: String) {
        emit("error: \(message)", level: "failure", terminal: standardError)
    }

    /// Writes an unprefixed line to stderr and the durable session record.
    /// Recovery commands use this to preserve their established terminal
    /// stream and exact indentation.
    public func stderr(_ message: String = "") {
        emit(message, level: "stderr", terminal: standardError)
    }

    /// Writes a prompt to the terminal without a trailing newline while still
    /// recording it as one complete, immediately durable text-log line.
    public func prompt(_ message: String) {
        emit(message, level: "prompt", terminal: standardOutput, terminalNewline: false)
    }

    /// Runs `body`, recording how long it took under `phase`.
    ///
    /// A throwing phase is recorded too: how long a run spent before failing is
    /// the evidence a slow failure needs, and discarding it on the error path
    /// would lose exactly the case worth measuring.
    @discardableResult
    public func timed<T>(_ phase: String, _ body: () throws -> T) rethrows -> T {
        let start = ContinuousClock.now
        do {
            let value = try body()
            record(phase: phase, since: start)
            return value
        } catch {
            record(phase: phase, since: start)
            throw error
        }
    }

    public var timings: [PhaseTiming] {
        mutex.lock()
        defer { mutex.unlock() }
        return phaseTimings
    }

    /// Emits one summary line, or nothing at all when no phase was timed.
    public func reportTimings() {
        let recorded = timings
        guard !recorded.isEmpty else { return }
        let parts = recorded.map { String(format: "%@ %.2fs", $0.phase, $0.seconds) }
        info("Timing: " + parts.joined(separator: ", "))
    }

    private func record(phase: String, since start: ContinuousClock.Instant) {
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        mutex.lock()
        phaseTimings.append(PhaseTiming(phase: phase, seconds: seconds))
        mutex.unlock()
    }

    /// Debug details are deliberately lazy: archive-record expansion can be
    /// expensive and must cost nothing in an ordinary session.
    public func debug(_ message: () -> String) {
        guard debugDescriptor != nil else { return }
        mutex.lock()
        writeDebugEventLocked(level: "debug", message: message())
        mutex.unlock()
    }

    private func emit(
        _ message: String,
        level: String,
        terminal: FileHandle,
        terminalNewline: Bool = true
    ) {
        mutex.lock()
        emitLocked(
            message,
            level: level,
            terminal: terminal,
            terminalNewline: terminalNewline
        )
        mutex.unlock()
    }

    private func emitLocked(
        _ message: String,
        level: String,
        terminal: FileHandle,
        terminalNewline: Bool = true
    ) {
        let terminalText = terminalNewline ? message + "\n" : message
        do {
            try terminal.write(contentsOf: Data(terminalText.utf8))
        } catch {
            // Keep the durable record authoritative even when a wrapper has
            // closed its terminal pipe.
        }

        let timestamp = Self.lineTimestamp(Date())
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false)
        let persisted = lines.map { "\(timestamp) \($0)\n" }.joined()
        Self.writeAndSynchronize(Data(persisted.utf8), to: textDescriptor)
        writeDebugEventLocked(level: level, message: message)
    }

    private func writeDebugEventLocked(level: String, message: String) {
        guard let debugDescriptor else { return }
        let event = DebugEvent(timestamp: Self.lineTimestamp(Date()), level: level, message: message)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(event)
            data.append(0x0A)
            Self.writeAndSynchronize(data, to: debugDescriptor)
        } catch {
            fatalError("could not encode session debug event: \(error)")
        }
    }

    private static func openNewFile(_ url: URL) throws -> Int32 {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard descriptor >= 0 else { throw posixError() }
        return descriptor
    }

    private static func writeAndSynchronize(_ data: Data, to descriptor: Int32) {
        do {
            try data.withUnsafeBytes { rawBuffer in
                guard var address = rawBuffer.baseAddress else { return }
                var remaining = rawBuffer.count
                while remaining > 0 {
                    let count = Darwin.write(descriptor, address, remaining)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw posixError() }
                    address = address.advanced(by: count)
                    remaining -= count
                }
            }
            while fsync(descriptor) != 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
        } catch {
            fatalError("could not durably write session log: \(error)")
        }
    }

    private static func reserveTextLog(
        command: String,
        startingAt date: Date,
        logsDirectory: URL
    ) throws -> (session: String, url: URL, descriptor: Int32) {
        var candidate = date
        while true {
            let session = "\(command)-\(fileTimestamp(candidate))"
            let text = logsDirectory.appending(path: "\(session).log")
            let debug = logsDirectory.appending(path: "\(session).jsonl")
            if FileManager.default.fileExists(atPath: debug.path) {
                candidate.addTimeInterval(1)
                continue
            }
            let descriptor = open(text.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            if descriptor >= 0 {
                do {
                    try lock(descriptor, operation: LOCK_SH)
                    return (session, text, descriptor)
                } catch {
                    close(descriptor)
                    try? FileManager.default.removeItem(at: text)
                    throw error
                }
            }
            if errno == EEXIST {
                candidate.addTimeInterval(1)
                continue
            }
            throw posixError()
        }
    }

    /// Serializes prune/reserve/publish across processes sharing one install.
    /// The text file still uses O_EXCL so a stale or uncooperative writer can
    /// never be truncated.
    private static func acquireAllocationLock(in logsDirectory: URL) throws -> Int32 {
        let url = logsDirectory.appending(path: ".session.lock")
        let descriptor = open(url.path, O_RDWR | O_CREAT, 0o644)
        guard descriptor >= 0 else { throw posixError() }
        do {
            try lock(descriptor, operation: LOCK_EX)
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func prune(logsDirectory: URL, keepingExisting limit: Int) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: logsDirectory.path)
        var sessions: [String: RecognizedSession] = [:]
        for name in names {
            guard let recognized = recognizedSession(name) else { continue }
            sessions[recognized.key] = recognized
        }

        let ordered = sessions.values.sorted {
            ($0.timestamp, $0.command) < ($1.timestamp, $1.command)
        }
        var removeCount = max(0, ordered.count - limit)
        for session in ordered where removeCount > 0 {
            let textURL = logsDirectory.appending(path: "\(session.key).log")
            let descriptor = open(textURL.path, O_RDONLY)
            if descriptor >= 0 {
                if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                    let lockError = errno
                    close(descriptor)
                    if lockError == EWOULDBLOCK || lockError == EAGAIN {
                        // A live SessionLog holds a shared lock for its entire
                        // lifetime. Retention may temporarily exceed its limit
                        // rather than delete a session still being written.
                        continue
                    }
                    errno = lockError
                    throw posixError()
                }
            } else if errno != ENOENT {
                throw posixError()
            }
            defer {
                if descriptor >= 0 { close(descriptor) }
            }

            for suffix in ["log", "jsonl"] {
                let url = logsDirectory.appending(path: "\(session.key).\(suffix)")
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
            removeCount -= 1
        }
    }

    private static func lock(_ descriptor: Int32, operation: Int32) throws {
        while flock(descriptor, operation) != 0 {
            if errno == EINTR { continue }
            throw posixError()
        }
    }

    private static func recognizedSession(_ name: String) -> RecognizedSession? {
        let pattern = #"^(run|setup|restore)-(\d{4}-\d{2}-\d{2}T\d{6}Z)\.(log|jsonl)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        guard let match = expression.firstMatch(in: name, range: range),
              let commandRange = Range(match.range(at: 1), in: name),
              let timestampRange = Range(match.range(at: 2), in: name)
        else {
            return nil
        }
        let command = String(name[commandRange])
        let timestamp = String(name[timestampRange])
        return RecognizedSession(command: command, timestamp: timestamp)
    }

    private static func publishLatest(_ textLogURL: URL, in logsDirectory: URL) throws {
        let manager = FileManager.default
        let temporary = logsDirectory.appending(path: ".latest-\(UUID().uuidString).tmp")
        guard symlink(textLogURL.lastPathComponent, temporary.path) == 0 else {
            throw posixError()
        }
        let latest = logsDirectory.appending(path: "latest.log")
        guard rename(temporary.path, latest.path) == 0 else {
            let error = posixError()
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    private static func fileTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    private static func lineTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

private struct RecognizedSession {
    let command: String
    let timestamp: String

    var key: String { "\(command)-\(timestamp)" }
}

private struct DebugEvent: Encodable {
    let timestamp: String
    let level: String
    let message: String
}
