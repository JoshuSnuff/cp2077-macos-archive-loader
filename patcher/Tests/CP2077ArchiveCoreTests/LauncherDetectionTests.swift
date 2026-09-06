import CP2077ArchiveCore
import Foundation
import Testing

private func writeLauncher(_ game: TestGame, _ name: String, executable: Bool = true) throws -> URL {
    let url = game.gameRoot.appending(path: name)
    try Data("#!/usr/bin/env bash\nexec ./Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077\n".utf8)
        .write(to: url)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(executable ? 0o755 : 0o644))],
        ofItemAtPath: url.path
    )
    return url.normalizedFileURL
}

@Test func knownLaunchersComeFirstInPriorityOrder() throws {
    let game = try TestGame()
    defer { game.cleanUp() }
    _ = try writeLauncher(game, "aaa_custom.sh")
    let red4ext = try writeLauncher(game, "launch_red4ext.sh")
    let modded = try writeLauncher(game, "launch_modded.sh")

    let detected = try LauncherDetection.detect(game: game.install)

    #expect(detected.map(\.url) == [modded, red4ext, game.gameRoot.appending(path: "aaa_custom.sh").normalizedFileURL])
    #expect(detected[0].isKnownName)
    #expect(detected[1].isKnownName)
    #expect(!detected[2].isKnownName)
}

@Test func nonExecutableScriptsAreIgnored() throws {
    let game = try TestGame()
    defer { game.cleanUp() }
    _ = try writeLauncher(game, "notes.sh", executable: false)

    #expect(try LauncherDetection.detect(game: game.install).isEmpty)
}

@Test func ourOwnDirectoryIsNeverSearched() throws {
    let game = try TestGame()
    defer { game.cleanUp() }
    let ours = game.install.loaderDirectory.appending(path: "setup.sh")
    try FileManager.default.createDirectory(at: game.install.loaderDirectory, withIntermediateDirectories: true)
    try Data("#!/usr/bin/env bash\n".utf8).write(to: ours)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o755))],
        ofItemAtPath: ours.path
    )

    #expect(try LauncherDetection.detect(game: game.install).isEmpty)
}

@Test func theRunCommandWrapsTheLauncherRelativeToTheGameDirectory() throws {
    let game = try TestGame()
    defer { game.cleanUp() }
    let launcher = try writeLauncher(game, "launch_modded.sh")

    let command = LauncherDetection.runCommand(for: launcher, game: game.install)

    #expect(command == "./archive-loader/bin/archive-loader run -- ./launch_modded.sh")
}

@Test func detectionNeverModifiesTheLauncher() throws {
    let game = try TestGame()
    defer { game.cleanUp() }
    let launcher = try writeLauncher(game, "launch_modded.sh")
    let before = try Data(contentsOf: launcher)

    _ = try LauncherDetection.detect(game: game.install)
    _ = LauncherDetection.runCommand(for: launcher, game: game.install)

    // "We never write another project's file" is absolute under the wrapper
    // model, and launch_modded.sh is a name cyberpunk2077-input-loader-mac
    // owns.
    #expect(try Data(contentsOf: launcher) == before)
}
