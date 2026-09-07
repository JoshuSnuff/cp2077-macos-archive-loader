import CP2077ArchiveCore
import Foundation
import Testing

private struct Fixture {
    let game: TestGame
    let manifest: BaselineManifest
    let official: [URL]

    var install: GameInstall { game.install }

    func mods() throws -> [URL] {
        try ModCollection.enabledMods(game: install)
    }

    func fingerprint() throws -> CacheFingerprint {
        try CacheFingerprint.compute(
            game: install,
            manifest: manifest,
            officialArchives: official,
            mods: try mods()
        )
    }

    @discardableResult
    func writeMod(_ name: String, hash: UInt64, payload: String) throws -> URL {
        let url = install.modsEnabledDirectory.appending(path: name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeTestArchive(to: url, records: [TestRecord(hash: hash, payload: Data(payload.utf8))])
        return url.normalizedFileURL
    }
}

private func fixture() throws -> Fixture {
    let game = try TestGame()
    try game.writeOfficial("basegame_1_engine.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("stock".utf8))
    ])
    let store = BaselineStore(game: game.install)
    let manifest = try store.capture(gameVersion: "2.3.1", storefront: "heroic")
    try store.publish(manifest)

    let f = Fixture(
        game: game,
        manifest: manifest,
        official: try game.install.officialMacArchives()
    )
    try f.writeMod("a.archive", hash: 0x1111, payload: "mod-a")
    try f.writeMod("b.archive", hash: 0x2222, payload: "mod-b")
    return f
}

@Test func theSameInputsProduceTheSameFingerprint() throws {
    let f = try fixture()
    defer { f.game.cleanUp() }

    #expect(try f.fingerprint().value == f.fingerprint().value)
    #expect(try f.fingerprint().value.count == 64)
}

@Test func editingAModChangesTheFingerprint() throws {
    let f = try fixture()
    defer { f.game.cleanUp() }
    let before = try f.fingerprint().value

    try f.writeMod("a.archive", hash: 0x1111, payload: "mod-a-edited")

    #expect(try f.fingerprint().value != before)
}

@Test func addingAModChangesTheFingerprint() throws {
    let f = try fixture()
    defer { f.game.cleanUp() }
    let before = try f.fingerprint().value

    try f.writeMod("c.archive", hash: 0x3333, payload: "mod-c")

    #expect(try f.fingerprint().value != before)
}

@Test func renamingAModToChangeLoadOrderChangesTheFingerprint() throws {
    let f = try fixture()
    defer { f.game.cleanUp() }
    let before = try f.fingerprint().value

    try FileManager.default.moveItem(
        at: f.install.modsEnabledDirectory.appending(path: "a.archive"),
        to: f.install.modsEnabledDirectory.appending(path: "z.archive")
    )

    #expect(try f.fingerprint().value != before)
}

/// The case the baseline generation id cannot cover: `PatchPlanner` plans over
/// the live official set, and `status` deliberately tolerates an archive that
/// appeared after capture.
@Test func anOfficialArchiveInstalledAfterCaptureChangesTheFingerprint() throws {
    let f = try fixture()
    defer { f.game.cleanUp() }
    let before = try f.fingerprint().value

    try f.game.writeOfficial("lang_de_text.archive", records: [
        TestRecord(hash: 0x4444, payload: Data("language-pack".utf8))
    ])

    let after = try CacheFingerprint.compute(
        game: f.install,
        manifest: f.manifest,
        officialArchives: try f.install.officialMacArchives(),
        mods: try f.mods()
    )
    #expect(after.value != before)
}

/// An archive absent from the baseline has no manifest digest to identify its
/// bytes. Size alone must not let an in-place rewrite reuse an image planned
/// for the old contents.
@Test func sameSizeChangesToAnOfficialArchiveInstalledAfterCaptureChangeTheFingerprint() throws {
    let f = try fixture()
    defer { f.game.cleanUp() }
    let languagePack = f.install.macContentArchiveDirectory
        .appending(path: "lang_de_text.archive")
    let original = Data("language-pack-v1".utf8)
    let replacement = Data("language-pack-v2".utf8)
    #expect(original.count == replacement.count)
    try original.write(to: languagePack)

    let before = try CacheFingerprint.compute(
        game: f.install,
        manifest: f.manifest,
        officialArchives: try f.install.officialMacArchives(),
        mods: try f.mods()
    )

    try replacement.write(to: languagePack)

    let after = try CacheFingerprint.compute(
        game: f.install,
        manifest: f.manifest,
        officialArchives: try f.install.officialMacArchives(),
        mods: try f.mods()
    )
    #expect(after.value != before.value)
}

@Test func aDifferentBaselineGenerationChangesTheFingerprint() throws {
    let f = try fixture()
    defer { f.game.cleanUp() }
    let before = try f.fingerprint().value

    let other = BaselineManifest(
        id: "20260101T000000Z",
        capturedAt: f.manifest.capturedAt,
        gameVersion: f.manifest.gameVersion,
        storefront: f.manifest.storefront,
        loaderVersion: f.manifest.loaderVersion,
        archives: f.manifest.archives
    )
    let after = try CacheFingerprint.compute(
        game: f.install,
        manifest: other,
        officialArchives: f.official,
        mods: try f.mods()
    )
    #expect(after.value != before)
}

@Test func theCanonicalInputNamesEveryInvalidationInput() throws {
    let f = try fixture()
    defer { f.game.cleanUp() }

    let input = try f.fingerprint().canonicalInput
    #expect(input.hasPrefix("archive-loader-cache-v2\n"))
    #expect(input.contains("patchFormat \(PatchFormat.current)\n"))
    #expect(input.contains("baseline \(f.manifest.id)\n"))
    #expect(input.contains("gameVersion 2.3.1\n"))
    #expect(input.contains(
        "official content/basegame_1_engine.archive "
            + "\(f.manifest.archives[0].size) \(f.manifest.archives[0].sha256)\n"
    ))
    #expect(input.contains("mod a.archive "))
    #expect(input.contains("mod b.archive "))
}
