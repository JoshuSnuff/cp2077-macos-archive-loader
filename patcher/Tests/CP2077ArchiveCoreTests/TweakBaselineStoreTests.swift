import CP2077ArchiveCore
import Foundation
import Testing

private func writeStubTweakBlob(_ game: TestGame, _ name: String, _ contents: String) throws -> URL {
    let directory = game.install.tweakCacheDirectory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: name)
    try Data(contents.utf8).write(to: url)
    return url
}

@Test func captureClonesPresentBlobsIntoTheGenerationAndLeavesEp1Optional() throws {
    let game = try TestGame()
    defer { game.cleanUp() }
    try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("stock".utf8)),
    ])
    _ = try writeStubTweakBlob(game, "tweakdb.bin", "base")

    let store = BaselineStore(game: game.install)
    let manifest = try store.capture(gameVersion: "2.3.1", storefront: "gog")

    #expect(manifest.tweaks.map(\.path) == ["r6/cache/tweakdb.bin"])
    #expect(try Data(contentsOf: store.generationDirectory(id: manifest.id)
        .appending(path: "r6/cache/tweakdb.bin")) == Data("base".utf8))
}

@Test func captureClonesBothBlobsAndRestorePutsBothBack() throws {
    let game = try TestGame()
    defer { game.cleanUp() }
    try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("stock".utf8)),
    ])
    let base = try writeStubTweakBlob(game, "tweakdb.bin", "base")
    let ep1 = try writeStubTweakBlob(game, "tweakdb_ep1.bin", "ep1")

    let store = BaselineStore(game: game.install)
    let manifest = try store.capture(gameVersion: "2.3.1", storefront: "gog")
    try store.publish(manifest)

    try Data("patched".utf8).write(to: base)
    try Data("patched".utf8).write(to: ep1)
    _ = try store.restore()

    #expect(try Data(contentsOf: base) == Data("base".utf8))
    #expect(try Data(contentsOf: ep1) == Data("ep1".utf8))
}

@Test func corruptTweakGenerationIsRejectedBeforeArchivesOrBlobsAreReplaced() throws {
    let game = try TestGame()
    defer { game.cleanUp() }
    let archive = try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("stock".utf8)),
    ])
    let blob = try writeStubTweakBlob(game, "tweakdb.bin", "base")
    let store = BaselineStore(game: game.install)
    let manifest = try store.capture(gameVersion: "2.3.1", storefront: "gog")
    try store.publish(manifest)

    let archiveBefore = Data("live-archive-must-remain".utf8)
    let blobBefore = Data("live-blob-must-remain".utf8)
    try archiveBefore.write(to: archive)
    try blobBefore.write(to: blob)
    let tweakEntry = try #require(manifest.tweaks.first)
    let corruptSource = store.generationDirectory(id: manifest.id).appending(path: tweakEntry.path)
    try Data("xxxx".utf8).write(to: corruptSource)

    #expect(throws: (any Error).self) { _ = try store.restore() }
    #expect(try Data(contentsOf: archive) == archiveBefore)
    #expect(try Data(contentsOf: blob) == blobBefore)
}

@Test func restoreFromLegacyArchiveOnlyGenerationLeavesLiveBlobsAlone() throws {
    let game = try TestGame()
    defer { game.cleanUp() }
    try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("stock".utf8)),
    ])
    let store = BaselineStore(game: game.install)
    let manifest = try store.capture(gameVersion: "2.3.1", storefront: "gog")
    try store.publish(manifest)
    let base = try writeStubTweakBlob(game, "tweakdb.bin", "untouched")

    _ = try store.restore()

    #expect(try Data(contentsOf: base) == Data("untouched".utf8))
    #expect(try store.compareLiveTweaks(deep: true).isPristine)
}

@Test func compareLiveTweaksReportsDriftAndMissingEntries() throws {
    let game = try TestGame()
    defer { game.cleanUp() }
    try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("stock".utf8)),
    ])
    let base = try writeStubTweakBlob(game, "tweakdb.bin", "base")
    _ = try writeStubTweakBlob(game, "tweakdb_ep1.bin", "ep1")
    let store = BaselineStore(game: game.install)
    try store.publish(try store.capture(gameVersion: "2.3.1", storefront: "gog"))

    try Data("changed".utf8).write(to: base)
    #expect(try store.compareLiveTweaks(deep: true).drifted == ["r6/cache/tweakdb.bin"])

    try FileManager.default.removeItem(at: base)
    let comparison = try store.compareLiveTweaks(deep: true)
    #expect(comparison.missing == ["r6/cache/tweakdb.bin"])
    #expect(!comparison.isRestorable)
}

@Test func captureRejectsATweakBlobReachedThroughASymlinkEscape() throws {
    let game = try TestGame()
    defer { game.cleanUp() }
    try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("stock".utf8)),
    ])

    let outside = game.root.appending(path: "outside", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: outside.appending(path: "cache"), withIntermediateDirectories: true)
    try Data("outside".utf8).write(to: outside.appending(path: "cache/tweakdb.bin"))
    try FileManager.default.createDirectory(at: game.gameRoot.appending(path: "r6"), withIntermediateDirectories: true)
    try FileManager.default.removeItem(at: game.gameRoot.appending(path: "r6"))
    try FileManager.default.createSymbolicLink(
        at: game.gameRoot.appending(path: "r6"),
        withDestinationURL: outside
    )

    #expect(throws: BaselineError.self) {
        _ = try BaselineStore(game: game.install).capture(gameVersion: "2.3.1", storefront: "gog")
    }
}

@Test func recaptureIsSafeWhenArchivesAndRecordedBlobsMatch() throws {
    let game = try TestGame()
    defer { game.cleanUp() }
    try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("stock".utf8)),
    ])
    _ = try writeStubTweakBlob(game, "tweakdb.bin", "base")
    let store = BaselineStore(game: game.install)
    let manifest = try store.capture(gameVersion: "2.3.1", storefront: "gog")
    try store.publish(manifest)

    #expect(try store.canRecaptureFromLive() == .safe(previousGeneration: manifest.id))
}

@Test func recaptureRefusesWhenARecordedBlobDrifted() throws {
    let game = try TestGame()
    defer { game.cleanUp() }
    try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("stock".utf8)),
    ])
    let base = try writeStubTweakBlob(game, "tweakdb.bin", "base")
    let store = BaselineStore(game: game.install)
    try store.publish(try store.capture(gameVersion: "2.3.1", storefront: "gog"))
    try Data("changed".utf8).write(to: base)

    guard case let .refused(reason) = try store.canRecaptureFromLive() else {
        Issue.record("expected recapture to be refused")
        return
    }
    #expect(reason.contains("verify"))
}

@Test func legacyArchiveOnlyRecaptureRefusesLiveTweakBlobs() throws {
    let game = try TestGame()
    defer { game.cleanUp() }
    try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("stock".utf8)),
    ])
    let store = BaselineStore(game: game.install)
    let manifest = try store.capture(gameVersion: "2.3.1", storefront: "gog")
    try store.publish(manifest)
    _ = try writeStubTweakBlob(game, "tweakdb.bin", "possibly-modified")

    guard case let .refused(reason) = try store.canRecaptureFromLive() else {
        Issue.record("expected legacy archive-only recapture to be refused")
        return
    }
    #expect(reason.contains("archive-only"))
    #expect(reason.contains("TweakDB"))
}

@Test func legacyArchiveOnlyCaptureDoesNotRecordLiveTweakBlobs() throws {
    let game = try TestGame()
    defer { game.cleanUp() }
    try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("stock".utf8)),
    ])
    let store = BaselineStore(game: game.install)
    let manifest = try store.capture(gameVersion: "2.3.1", storefront: "gog")
    try store.publish(manifest)
    _ = try writeStubTweakBlob(game, "tweakdb.bin", "possibly-modified")

    let recaptured = try? store.capture(gameVersion: "2.3.1", storefront: "gog")
    #expect(recaptured == nil)
    #expect(try store.publishedManifest()?.id == manifest.id)
}

@Test func legacyArchiveOnlyRecaptureWithoutLiveTweakBlobsRemainsSupported() throws {
    let game = try TestGame()
    defer { game.cleanUp() }
    try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("stock".utf8)),
    ])
    let store = BaselineStore(game: game.install)
    let manifest = try store.capture(gameVersion: "2.3.1", storefront: "gog")
    try store.publish(manifest)

    let recaptured = try store.capture(gameVersion: "2.3.1", storefront: "gog")
    #expect(recaptured.tweaks.isEmpty)
}
