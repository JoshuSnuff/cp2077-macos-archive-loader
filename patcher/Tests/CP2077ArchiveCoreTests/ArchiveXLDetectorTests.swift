import CP2077ArchiveCore
import Foundation
import Testing

private func archiveXLFixture() throws -> (root: URL, game: GameInstall, mods: URL) {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "archivexl-fixture-\(UUID().uuidString)", directoryHint: .isDirectory)
    let game = root.appending(path: "Game", directoryHint: .isDirectory)
    let mods = game.appending(path: "archive-loader/mods/tweaks", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: mods, withIntermediateDirectories: true)
    return (root, GameInstall(root: game), mods)
}

@Test func exactV1MarkersAreReportedWithTheirManifestPaths() throws {
    let fixture = try archiveXLFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try Data("requires: [ArchiveXL]\n".utf8)
        .write(to: fixture.mods.appending(path: "requires.yaml"))
    try Data("dependencies: [ArchiveXL]\n".utf8)
        .write(to: fixture.mods.appending(path: "dependencies.tweak"))

    let inventory = try ArchiveXLDetector.scan(game: fixture.game)

    #expect(inventory.schema == "archive-loader-archivexl-markers/v1")
    #expect(inventory.matches.count == 2)
    #expect(inventory.matches.allSatisfy { $0.path.contains("archive-loader/mods/tweaks") })
    #expect(inventory.matches.allSatisfy { $0.mod != nil })
    #expect(inventory.diagnostics.allSatisfy {
        $0.contains("archive-loader-archivexl-markers/v1")
    })
}

@Test func installedPluginNamesDoNotCreateFrameworkRequirements() throws {
    let fixture = try archiveXLFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let plugins = fixture.game.root.appending(path: "red4ext/plugins", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: plugins.appending(path: "ArchiveXL"), withIntermediateDirectories: true)
    try Data("plugin".utf8).write(to: plugins.appending(path: "ArchiveXL.dylib"))
    try Data("other".utf8).write(to: plugins.appending(path: "ArchiveXLish.dylib"))

    let inventory = try ArchiveXLDetector.scan(game: fixture.game)

    #expect(inventory.matches.isEmpty)
}

@Test func ordinaryArchivesUnknownMetadataAndUnrelatedPluginsAreIgnored() throws {
    let fixture = try archiveXLFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try Data("requires: [ArchiveXLExtra]\n".utf8)
        .write(to: fixture.mods.appending(path: "unknown.yaml"))
    try Data("ArchiveXL\n".utf8)
        .write(to: fixture.mods.appending(path: "notes.yaml"))
    let plugins = fixture.game.root.appending(path: "red4ext/plugins", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
    try Data("other".utf8).write(to: plugins.appending(path: "Other.dylib"))
    try Data("opaque ArchiveXL marker".utf8)
        .write(to: fixture.root.appending(path: "ordinary.archive"))

    #expect(try ArchiveXLDetector.scan(game: fixture.game).matches.isEmpty)
}
