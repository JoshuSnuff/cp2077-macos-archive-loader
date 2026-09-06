import CP2077ArchiveCore
import Foundation
import Testing

private struct ScriptFixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "archive-loader-supervisor-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @discardableResult
    func write(_ name: String, _ body: String) throws -> URL {
        let url = directory.appending(path: name)
        try Data("#!/usr/bin/env bash\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: url.path
        )
        return url
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

@Test func aCleanExitIsReportedAsZero() throws {
    let fixture = try ScriptFixture()
    defer { fixture.cleanUp() }
    let script = try fixture.write("ok.sh", "exit 0")

    let outcome = try LaunchSupervisor.run(
        executable: script,
        arguments: [],
        workingDirectory: fixture.directory
    )

    #expect(outcome.exitCode == 0)
    #expect(!outcome.wasSignalled)
    #expect(outcome.reportableCode == 0)
}

@Test func aNonZeroExitIsPassedThrough() throws {
    let fixture = try ScriptFixture()
    defer { fixture.cleanUp() }
    let script = try fixture.write("fail.sh", "exit 3")

    let outcome = try LaunchSupervisor.run(
        executable: script,
        arguments: [],
        workingDirectory: fixture.directory
    )

    #expect(outcome.exitCode == 3)
    #expect(outcome.reportableCode == 3)
}

@Test func argumentsReachTheChild() throws {
    let fixture = try ScriptFixture()
    defer { fixture.cleanUp() }
    let script = try fixture.write("args.sh", #"[ "$1" = "alpha" ] && [ "$2" = "two words" ] && exit 0; exit 9"#)

    let outcome = try LaunchSupervisor.run(
        executable: script,
        arguments: ["alpha", "two words"],
        workingDirectory: fixture.directory
    )

    #expect(outcome.exitCode == 0)
}

@Test func theEnvironmentIsPassedThroughUntouched() throws {
    let fixture = try ScriptFixture()
    defer { fixture.cleanUp() }
    let marker = fixture.directory.appending(path: "env.txt")
    let script = try fixture.write("env.sh", "printf '%s' \"$ARCHIVE_LOADER_TEST_VALUE\" > '\(marker.path)'")

    setenv("ARCHIVE_LOADER_TEST_VALUE", "carried", 1)
    defer { unsetenv("ARCHIVE_LOADER_TEST_VALUE") }

    _ = try LaunchSupervisor.run(
        executable: script,
        arguments: [],
        workingDirectory: fixture.directory
    )

    #expect(try String(contentsOf: marker, encoding: .utf8) == "carried")
}

@Test func aChildKilledBySignalIsReportedAsSignalled() throws {
    let fixture = try ScriptFixture()
    defer { fixture.cleanUp() }
    let script = try fixture.write("suicide.sh", "kill -TERM $$; sleep 5")

    let outcome = try LaunchSupervisor.run(
        executable: script,
        arguments: [],
        workingDirectory: fixture.directory
    )

    #expect(outcome.wasSignalled)
    #expect(outcome.signalNumber == SIGTERM)
    #expect(outcome.reportableCode == 128 + SIGTERM)
}

@Test func theChildPIDIsReportedWhileItRuns() throws {
    let fixture = try ScriptFixture()
    defer { fixture.cleanUp() }
    let script = try fixture.write("quick.sh", "exit 0")

    var reported: pid_t = 0
    _ = try LaunchSupervisor.run(
        executable: script,
        arguments: [],
        workingDirectory: fixture.directory,
        onStarted: { reported = $0 }
    )

    #expect(reported > 0)
}

@Test func aMissingLauncherIsRefusedBeforeAnythingStarts() throws {
    let fixture = try ScriptFixture()
    defer { fixture.cleanUp() }

    #expect(throws: LaunchError.self) {
        _ = try LaunchSupervisor.run(
            executable: fixture.directory.appending(path: "absent.sh"),
            arguments: [],
            workingDirectory: fixture.directory
        )
    }
}
