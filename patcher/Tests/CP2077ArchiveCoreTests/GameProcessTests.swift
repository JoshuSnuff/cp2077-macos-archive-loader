import CP2077ArchiveCore
import Foundation
import Testing

/// A small executable built at a path we own, so tests can match on a distinct
/// executable path without depending on what else is running on the machine.
private struct FakeProcess {
    let directory: URL
    let executable: URL

    init(name: String = "Cyberpunk2077") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "archive-loader-process-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appending(path: name)
        let source = directory.appending(path: "process.c")
        try Data(
            "#include <stdlib.h>\n#include <unistd.h>\nint main(int argc, char **argv) { if (argc > 1) sleep((unsigned int)atoi(argv[1])); return 0; }\n".utf8
        ).write(to: source)

        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        compiler.arguments = ["-O0", "-o", executable.path, source.path]
        try compiler.run()
        compiler.waitUntilExit()
        try FileManager.default.removeItem(at: source)
        guard compiler.terminationStatus == 0 else {
            throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "could not build test process"])
        }
    }

    func launch(seconds: Int) throws -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["\(seconds)"]
        try process.run()
        return process
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

@Test func nothingIsRunningWhenNothingWasLaunched() throws {
    let fake = try FakeProcess()
    defer { fake.cleanUp() }

    #expect(GameProcess.runningPIDs(matching: fake.executable).isEmpty)
}

@Test func aLaunchedProcessIsSeenAndItsExitIsSeenToo() throws {
    let fake = try FakeProcess()
    defer { fake.cleanUp() }

    let process = try fake.launch(seconds: 30)
    defer { process.terminate() }

    #expect(GameProcess.waitForStart(matching: fake.executable, timeout: 5))
    #expect(GameProcess.runningPIDs(matching: fake.executable).contains(process.processIdentifier))

    process.terminate()
    process.waitUntilExit()
    GameProcess.waitForExit(matching: fake.executable)

    #expect(GameProcess.runningPIDs(matching: fake.executable).isEmpty)
}

@Test func aProcessThatAppearsLateIsStillCaughtWithinTheGracePeriod() throws {
    let fake = try FakeProcess()
    defer { fake.cleanUp() }

    // Stands in for `open -a`, which returns before the app is observable.
    // A bare check here would see nothing, restore, and only then would the
    // game start — against restored vanilla archives.
    //
    // A shell that sleeps and then execs, rather than a Swift thread: no
    // captured state, so nothing to reason about under strict concurrency.
    let delayed = Process()
    delayed.executableURL = URL(fileURLWithPath: "/bin/sh")
    delayed.arguments = ["-c", "sleep 1; exec '\(fake.executable.path)' 30"]
    try delayed.run()
    defer {
        for pid in GameProcess.runningPIDs(matching: fake.executable) { kill(pid, SIGTERM) }
        delayed.terminate()
    }

    #expect(GameProcess.waitForStart(matching: fake.executable, timeout: 5))
}

@Test func theWatcherRemembersASessionThatHasAlreadyEnded() throws {
    let fake = try FakeProcess()
    defer { fake.cleanUp() }

    let watcher = GameWatcher(executable: fake.executable)
    watcher.start()
    defer { watcher.stop() }

    let process = try fake.launch(seconds: 1)
    process.waitUntilExit()
    GameProcess.waitForExit(matching: fake.executable)

    // Without this, a foreground launcher — which has already quit the game by
    // the time it returns — is indistinguishable from one that never started
    // it, and every ordinary run would pay the full startup grace period.
    #expect(watcher.everSeen)
}

@Test func theWatcherReportsNothingWhenNoGameEverRan() throws {
    let fake = try FakeProcess()
    defer { fake.cleanUp() }

    let watcher = GameWatcher(executable: fake.executable)
    watcher.start()
    Thread.sleep(forTimeInterval: 0.5)
    watcher.stop()

    #expect(!watcher.everSeen)
}

@Test func theWaitGivesUpWhenNothingEverStarts() throws {
    let fake = try FakeProcess()
    defer { fake.cleanUp() }

    let began = Date()
    #expect(!GameProcess.waitForStart(matching: fake.executable, timeout: 0.5))
    #expect(Date().timeIntervalSince(began) < 3.0)
}

@Test func aDifferentExecutableAtTheSameNameIsNotOurs() throws {
    let ours = try FakeProcess()
    let theirs = try FakeProcess()
    defer {
        ours.cleanUp()
        theirs.cleanUp()
    }

    let process = try theirs.launch(seconds: 30)
    defer { process.terminate() }
    _ = GameProcess.waitForStart(matching: theirs.executable, timeout: 5)

    // Matching on the full executable path, not the process name: another
    // copy of the game elsewhere on disk is not this installation's session.
    #expect(GameProcess.runningPIDs(matching: ours.executable).isEmpty)
}

@Test func theGameExecutablePathIsDerivedFromTheInstall() {
    let game = GameInstall(root: URL(fileURLWithPath: "/games/Cyberpunk 2077", isDirectory: true))

    #expect(GameProcess.executable(in: game).path
        == "/games/Cyberpunk 2077/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077")
}
