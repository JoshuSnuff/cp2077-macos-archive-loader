import CP2077ArchiveCore
import Foundation
import Testing

private func capturedGame() throws -> (TestGame, BaselineStore, BaselineManifest) {
    let game = try TestGame()
    try game.writeOfficial("basegame_1_engine.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("content-stock".utf8))
    ])
    try game.writeEP1("ep1_1_main.archive", records: [
        TestRecord(hash: 0x2222, payload: Data("ep1-stock".utf8))
    ])
    let store = BaselineStore(game: game.install)
    let manifest = try store.capture(gameVersion: "2.3.1", storefront: "heroic")
    try store.publish(manifest)
    return (game, store, manifest)
}

@Test func restoreReturnsEveryRecordedArchiveToItsCapturedBytes() throws {
    let (game, store, manifest) = try capturedGame()
    defer { game.cleanUp() }

    let target = game.gameRoot.appending(path: "archive/Mac/content/basegame_1_engine.archive")
    try Data("patched rubbish".utf8).write(to: target)

    var restored: [URL] = []
    let result = try store.restore { restored.append($0) }

    #expect(result.count == manifest.archives.count)
    #expect(restored.count == manifest.archives.count)
    for entry in manifest.archives {
        let live = game.gameRoot.appending(path: "archive/Mac/\(entry.path)")
        #expect(try Hashes.sha256Hex(ofFileAt: live) == entry.sha256)
    }
}

@Test func restoreWithoutAPublishedBaselineRefuses() throws {
    let game = try TestGame()
    defer { game.cleanUp() }
    try game.writeOfficial("basegame_1_engine.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("stock".utf8))
    ])

    #expect(throws: BaselineError.self) {
        _ = try BaselineStore(game: game.install).restore()
    }
}

@Test func aCleanInstallComparesAsPristine() throws {
    let (game, store, _) = try capturedGame()
    defer { game.cleanUp() }

    let comparison = try store.compareLive(deep: true)

    #expect(comparison.isPristine)
    #expect(comparison.isRestorable)
    #expect(comparison.matching.count == 2)
    #expect(comparison.drifted.isEmpty)
    #expect(comparison.missing.isEmpty)
    #expect(comparison.unrecorded.isEmpty)
}

@Test func aChangedArchiveIsReportedAsDrift() throws {
    let (game, store, _) = try capturedGame()
    defer { game.cleanUp() }
    try Data("patched rubbish".utf8)
        .write(to: game.gameRoot.appending(path: "archive/Mac/content/basegame_1_engine.archive"))

    let comparison = try store.compareLive(deep: true)

    #expect(comparison.drifted == ["content/basegame_1_engine.archive"])
    #expect(!comparison.isPristine)
    // Drift is recoverable: the recorded bytes are still there to restore.
    #expect(comparison.isRestorable)
}

@Test func aShallowComparisonNoticesASizeChangeWithoutHashing() throws {
    let (game, store, _) = try capturedGame()
    defer { game.cleanUp() }
    try Data(repeating: 0x41, count: 999_999)
        .write(to: game.gameRoot.appending(path: "archive/Mac/content/basegame_1_engine.archive"))

    let comparison = try store.compareLive(deep: false)

    #expect(comparison.drifted == ["content/basegame_1_engine.archive"])
}

@Test func aVanishedRecordedArchiveMakesTheBaselineUnrestorable() throws {
    let (game, store, _) = try capturedGame()
    defer { game.cleanUp() }
    try FileManager.default.removeItem(
        at: game.gameRoot.appending(path: "archive/Mac/ep1/ep1_1_main.archive")
    )

    let comparison = try store.compareLive(deep: true)

    #expect(comparison.missing == ["ep1/ep1_1_main.archive"])
    #expect(!comparison.isRestorable)
}

@Test func aLanguagePackAddedAfterCaptureIsReportedButNeverActedOn() throws {
    let (game, store, _) = try capturedGame()
    defer { game.cleanUp() }
    // The official archive set is user-dependent and can grow after capture.
    // This is a normal event, not evidence of tampering.
    try game.writeOfficial("lang_de_voice.archive", records: [
        TestRecord(hash: 0x3333, payload: Data("added later".utf8))
    ])

    let comparison = try store.compareLive(deep: true)

    #expect(comparison.unrecorded == ["content/lang_de_voice.archive"])
    #expect(comparison.isRestorable)
    #expect(comparison.isPristine)

    _ = try store.restore()

    #expect(FileManager.default.fileExists(
        atPath: game.gameRoot.appending(path: "archive/Mac/content/lang_de_voice.archive").path
    ))
}
