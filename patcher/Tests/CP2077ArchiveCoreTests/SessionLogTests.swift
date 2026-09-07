@testable import CP2077ArchiveCore
import Foundation
import Testing

private struct LogFixture {
    let root: URL
    let logs: URL
    let standardOutput: URL
    let standardError: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "session-log-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        logs = root.appending(path: "logs", directoryHint: .isDirectory)
        standardOutput = root.appending(path: "stdout")
        standardError = root.appending(path: "stderr")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: standardOutput.path, contents: nil)
        FileManager.default.createFile(atPath: standardError.path, contents: nil)
    }

    func outputHandles() throws -> (FileHandle, FileHandle) {
        (try FileHandle(forWritingTo: standardOutput), try FileHandle(forWritingTo: standardError))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func date(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}

private func read(_ url: URL) throws -> String {
    String(decoding: try Data(contentsOf: url), as: UTF8.self)
}

@Test func everyTerminalLineIsImmediatelyPresentInTheTextLog() throws {
    let fixture = try LogFixture()
    defer { fixture.cleanUp() }
    let (output, error) = try fixture.outputHandles()
    defer {
        try? output.close()
        try? error.close()
    }

    let log = try SessionLog(
        command: "run",
        logsDirectory: fixture.logs,
        debug: false,
        date: date("2026-09-07T08:15:30Z"),
        standardOutput: output,
        standardError: error
    )

    log.step("Restoring archives...")
    #expect(try read(log.textLogURL).contains("1. Restoring archives...\n"))

    log.detail("basegame_1_engine.archive")
    log.warning("using the vanilla fallback")
    log.failure("restore failed")

    let terminal = try read(fixture.standardOutput) + read(fixture.standardError)
    let persistedMessages = try read(log.textLogURL)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .dropLast()
        .map { line in
            String(line.split(separator: " ", maxSplits: 1)[1]) + "\n"
        }
        .joined()

    #expect(terminal == persistedMessages)
    #expect(try read(fixture.standardOutput) == "1. Restoring archives...\n  basegame_1_engine.archive\n")
    #expect(try read(fixture.standardError) == "warning: using the vanilla fallback\nerror: restore failed\n")
}

@Test func retentionRemovesTheOldestSessionAsAPairAndPreservesUnrelatedFiles() throws {
    let fixture = try LogFixture()
    defer { fixture.cleanUp() }
    try FileManager.default.createDirectory(at: fixture.logs, withIntermediateDirectories: true)

    for second in 0..<20 {
        let stamp = String(format: "2026-09-07T0815%02dZ", second)
        try Data("text".utf8).write(to: fixture.logs.appending(path: "run-\(stamp).log"))
        if second == 0 {
            try Data("debug".utf8).write(to: fixture.logs.appending(path: "run-\(stamp).jsonl"))
        }
    }
    let unrelated = fixture.logs.appending(path: "keep-me.txt")
    try Data("user data".utf8).write(to: unrelated)
    let (output, error) = try fixture.outputHandles()
    defer {
        try? output.close()
        try? error.close()
    }

    _ = try SessionLog(
        command: "restore",
        logsDirectory: fixture.logs,
        debug: false,
        date: date("2026-09-07T08:16:00Z"),
        standardOutput: output,
        standardError: error
    )

    let names = try FileManager.default.contentsOfDirectory(atPath: fixture.logs.path)
    #expect(!names.contains("run-2026-09-07T081500Z.log"))
    #expect(!names.contains("run-2026-09-07T081500Z.jsonl"))
    #expect(names.contains("run-2026-09-07T081501Z.log"))
    #expect(names.filter { $0.hasSuffix(".log") && $0 != "latest.log" }.count == 20)
    #expect(try read(unrelated) == "user data")
}

@Test func latestIsAnAtomicStyleRelativeSymlinkToTheNewestSession() throws {
    let fixture = try LogFixture()
    defer { fixture.cleanUp() }
    let (output, error) = try fixture.outputHandles()
    defer {
        try? output.close()
        try? error.close()
    }

    _ = try SessionLog(
        command: "setup",
        logsDirectory: fixture.logs,
        debug: false,
        date: date("2026-09-07T08:15:30Z"),
        standardOutput: output,
        standardError: error
    )
    let newest = try SessionLog(
        command: "run",
        logsDirectory: fixture.logs,
        debug: false,
        date: date("2026-09-07T08:16:45Z"),
        standardOutput: output,
        standardError: error
    )

    let target = try FileManager.default.destinationOfSymbolicLink(
        atPath: fixture.logs.appending(path: "latest.log").path
    )
    #expect(target == newest.textLogURL.lastPathComponent)
    #expect(!target.hasPrefix("/"))
}

@Test func debugDoesNotEvaluateOrCreateJSONLWhenDisabled() throws {
    let fixture = try LogFixture()
    defer { fixture.cleanUp() }
    let (output, error) = try fixture.outputHandles()
    defer {
        try? output.close()
        try? error.close()
    }
    let log = try SessionLog(
        command: "run",
        logsDirectory: fixture.logs,
        debug: false,
        date: date("2026-09-07T08:15:30Z"),
        standardOutput: output,
        standardError: error
    )
    var evaluated = false

    log.debug {
        evaluated = true
        return "expensive detail"
    }

    #expect(!evaluated)
    #expect(log.debugLogURL == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.logs.path)
        .allSatisfy { !$0.hasSuffix(".jsonl") })
}

@Test func debugWritesMachineReadableEventsWithoutTerminalOutput() throws {
    let fixture = try LogFixture()
    defer { fixture.cleanUp() }
    let (output, error) = try fixture.outputHandles()
    defer {
        try? output.close()
        try? error.close()
    }
    let log = try SessionLog(
        command: "run",
        logsDirectory: fixture.logs,
        debug: true,
        date: date("2026-09-07T08:15:30Z"),
        standardOutput: output,
        standardError: error
    )

    log.step("Patching")
    log.debug { "sample archive set" }

    let debugURL = try #require(log.debugLogURL)
    let events = try read(debugURL).split(separator: "\n")
    #expect(events.count == 2)
    for event in events {
        _ = try JSONSerialization.jsonObject(with: Data(event.utf8))
    }
    let terminalOutput = try read(fixture.standardOutput)
    #expect(String(events[1]).contains("sample archive set"))
    #expect(!terminalOutput.contains("sample archive set"))
    #expect(try read(fixture.standardError).isEmpty)
}

@Test func timedPhasesAreRecordedInTheOrderTheyRan() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "session-timing-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }

    let log = try SessionLog(command: "run", logsDirectory: directory)
    log.timed("restore") { }
    let value = log.timed("patch") { 7 }

    #expect(value == 7)
    #expect(log.timings.map(\.phase) == ["restore", "patch"])
    #expect(log.timings.allSatisfy { $0.seconds >= 0 })
}

@Test func aThrowingPhaseIsStillTimed() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "session-timing-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }

    struct Boom: Error {}
    let log = try SessionLog(command: "run", logsDirectory: directory)

    #expect(throws: Boom.self) {
        try log.timed("patch") { throw Boom() }
    }
    #expect(log.timings.map(\.phase) == ["patch"])
}

@Test func reportTimingsWritesOneSummaryLineAndNothingWhenNoPhaseRan() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "session-timing-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }

    let empty = try SessionLog(command: "run", logsDirectory: directory)
    empty.reportTimings()
    #expect(!(try String(contentsOf: empty.textLogURL, encoding: .utf8)).contains("Timing:"))

    let log = try SessionLog(command: "run", logsDirectory: directory)
    log.timed("restore") { }
    log.reportTimings()

    let text = try String(contentsOf: log.textLogURL, encoding: .utf8)
    let summaries = text.split(separator: "\n").filter { $0.contains("Timing:") }
    #expect(summaries.count == 1)
    #expect(summaries[0].contains("restore "))
}

@Test func archiveObservationFiltersDescriptorsToArchivesUnderTheGameRoot() {
    let root = URL(fileURLWithPath: "/games/Cyberpunk 2077", isDirectory: true)

    let archives = GameProcess.archiveURLs(
        paths: [
            "/games/Cyberpunk 2077/archive/Mac/content/base.archive",
            "/games/Cyberpunk 2077/archive/Mac/ep1/expansion.archive",
            "/games/Cyberpunk 2077/archive/Mac/content/base.archive.tmp",
            "/games/Cyberpunk 2077 other/foreign.archive",
        ],
        under: root
    )

    #expect(Set(archives.map(\.path)) == Set<String>([
        "/games/Cyberpunk 2077/archive/Mac/content/base.archive",
        "/games/Cyberpunk 2077/archive/Mac/ep1/expansion.archive",
    ]))
}

@Test func archiveObservationReportsOnlyEvidenceCollectedAcrossBothSamples() {
    let first = URL(fileURLWithPath: "/game/first.archive")
    let second = URL(fileURLWithPath: "/game/second.archive")
    let missing = URL(fileURLWithPath: "/game/missing.archive")
    let observation = ArchiveObservation(
        expected: [first, second, missing],
        samples: [[first], [first, second]]
    )

    #expect(observation.observed == [first, second])
    #expect(observation.notObserved == [missing])
}

@Test func rawStderrLinesAreMirroredDurablyWithoutChangingTheirText() throws {
    let fixture = try LogFixture()
    defer { fixture.cleanUp() }
    let (output, error) = try fixture.outputHandles()
    defer {
        try? output.close()
        try? error.close()
    }
    let log = try SessionLog(
        command: "run",
        logsDirectory: fixture.logs,
        date: date("2026-09-07T08:15:30Z"),
        standardOutput: output,
        standardError: error
    )

    log.stderr("Recover with:")
    log.stderr("  cd '/games/Cyberpunk 2077'")

    #expect(try read(fixture.standardOutput).isEmpty)
    #expect(try read(fixture.standardError) == "Recover with:\n  cd '/games/Cyberpunk 2077'\n")
    #expect(try read(log.textLogURL).contains(" Recover with:\n"))
    #expect(try read(log.textLogURL).contains("   cd '/games/Cyberpunk 2077'\n"))
}

@Test func stoppingWaitsForAnInFlightArchiveSampleToBecomeObservable() throws {
    let archive = URL(fileURLWithPath: "/game/archive/Mac/content/base.archive")
    let samplingStarted = DispatchSemaphore(value: 0)
    let allowSamplingToFinish = DispatchSemaphore(value: 0)
    let stopReturned = DispatchSemaphore(value: 0)
    let watcher = GameWatcher(
        executable: URL(fileURLWithPath: "/game/Cyberpunk2077"),
        gameRoot: URL(fileURLWithPath: "/game", isDirectory: true),
        expectedArchives: [archive],
        archiveOpenSampleDelay: 0,
        runningPIDs: { _ in [123] },
        archiveSampler: { _, _ in
            samplingStarted.signal()
            allowSamplingToFinish.wait()
            return [archive]
        }
    )
    watcher.start()
    #expect(samplingStarted.wait(timeout: .now() + 2) == .success)

    let stopper = Thread {
        watcher.stop()
        stopReturned.signal()
    }
    stopper.start()
    #expect(stopReturned.wait(timeout: .now() + 0.1) == .timedOut)

    allowSamplingToFinish.signal()
    #expect(stopReturned.wait(timeout: .now() + 5) == .success)
    #expect(watcher.archiveObservation.observed == [archive])
}

private final class ConcurrentLogResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SessionLog] = []
    private var failures: [String] = []

    func record(_ result: Result<SessionLog, Error>) {
        lock.lock()
        defer { lock.unlock() }
        switch result {
        case let .success(log): storage.append(log)
        case let .failure(error): failures.append(String(describing: error))
        }
    }

    var snapshot: (logs: [SessionLog], failures: [String]) {
        lock.lock()
        defer { lock.unlock() }
        return (storage, failures)
    }
}

@Test func concurrentSameSecondSessionsAllocatePublishAndPruneWithoutColliding() throws {
    let fixture = try LogFixture()
    defer { fixture.cleanUp() }
    try FileManager.default.createDirectory(at: fixture.logs, withIntermediateDirectories: true)

    let results = ConcurrentLogResults()
    let group = DispatchGroup()
    let queue = DispatchQueue(label: "session-log-concurrency", attributes: .concurrent)
    for _ in 0..<16 {
        group.enter()
        queue.async {
            defer { group.leave() }
            results.record(Result {
                try SessionLog(
                    command: "run",
                    logsDirectory: fixture.logs,
                    date: date("2026-09-07T08:15:30Z"),
                    standardOutput: .nullDevice,
                    standardError: .nullDevice,
                    retentionLimit: 1
                )
            })
        }
    }
    #expect(group.wait(timeout: .now() + 10) == .success)

    let snapshot = results.snapshot
    let paths = snapshot.logs.map(\.textLogURL.path)
    #expect(snapshot.failures.isEmpty)
    #expect(snapshot.logs.count == 16)
    #expect(Set(paths).count == 16)
    #expect(paths.allSatisfy(FileManager.default.fileExists(atPath:)))
    let latest = try FileManager.default.destinationOfSymbolicLink(
        atPath: fixture.logs.appending(path: "latest.log").path
    )
    #expect(snapshot.logs.map(\.textLogURL.lastPathComponent).contains(latest))
}
