import CP2077ArchiveCore
import Foundation
import Testing

@Test func preflightPassesOnAWritableArm64Install() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let report = Preflight.run(game: game.install, architecture: "arm64")

    #expect(report.isClean)
    #expect(report.failures.isEmpty)
}

@Test func preflightFailsOnANonArm64Machine() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let report = Preflight.run(game: game.install, architecture: "x86_64")

    #expect(!report.isClean)
    #expect(report.failures.count == 1)
    #expect(report.failures[0].detail == "found x86_64")
}

@Test func preflightFailsOnANonWritableGameDirectory() throws {
    let game = try TestGame()
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: game.gameRoot.path
        )
        game.cleanUp()
    }
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o555))],
        ofItemAtPath: game.gameRoot.path
    )

    let report = Preflight.run(game: game.install, architecture: "arm64")

    #expect(!report.isClean)
    #expect(report.failures.contains { $0.description.contains("writable") })
}

@Test func currentArchitectureIsReported() {
    // Whatever the machine is, the probe must name it rather than guessing.
    #expect(!Preflight.currentArchitecture().isEmpty)
    #expect(Preflight.currentArchitecture() != "unknown")
}

@Test func loaderLayoutLivesEntirelyInsideOneDirectory() {
    let game = GameInstall(root: URL(fileURLWithPath: "/games/Cyberpunk 2077", isDirectory: true))
    let loader = "/games/Cyberpunk 2077/archive-loader"

    #expect(game.baselinesDirectory.path == loader + "/baselines")
    #expect(game.pristinePointer.path == loader + "/pristine")
    #expect(game.stateDirectory.path == loader + "/state")
    #expect(game.logsDirectory.path == loader + "/logs")
    #expect(game.modsEnabledDirectory.path == loader + "/mods/enabled")
    // The one path in the layout that is deliberately NOT ours.
    #expect(game.modStagingDirectory.path == "/games/Cyberpunk 2077/archive/Mac/mod")
}
