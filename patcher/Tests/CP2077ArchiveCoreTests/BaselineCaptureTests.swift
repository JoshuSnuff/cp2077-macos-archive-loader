import CP2077ArchiveCore
import Foundation
import Testing

private struct StopHere: Error {}

private func seedTwoArchives(_ game: TestGame) throws {
    try game.writeOfficial("basegame_1_engine.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("content-stock".utf8))
    ])
    try game.writeEP1("ep1_1_main.archive", records: [
        TestRecord(hash: 0x2222, payload: Data("ep1-stock".utf8))
    ])
}

@Test func captureRecordsEveryOfficialArchiveWithItsSizeAndHash() throws {
    let game = try TestGame()
    defer { game.cleanUp() }
    try seedTwoArchives(game)
    let store = BaselineStore(game: game.install)

    let manifest = try store.capture(gameVersion: "2.3.1", storefront: "heroic")

    #expect(manifest.archives.count == 2)
    #expect(manifest.archives.map(\.path).sorted()
        == ["content/basegame_1_engine.archive", "ep1/ep1_1_main.archive"])
    #expect(manifest.gameVersion == "2.3.1")
    #expect(manifest.storefront == "heroic")
    #expect(manifest.loaderVersion == LoaderVersion.current)
    for entry in manifest.archives {
        #expect(entry.size > 0)
        #expect(entry.sha256.count == 64)
    }
}

@Test func capturedClonesMatchTheLiveBytes() throws {
    let game = try TestGame()
    defer { game.cleanUp() }
    try seedTwoArchives(game)
    let store = BaselineStore(game: game.install)

    let manifest = try store.capture(gameVersion: "2.3.1", storefront: "heroic")

    let generation = store.generationDirectory(id: manifest.id)
    for entry in manifest.archives {
        let clone = generation.appending(path: entry.path)
        let live = game.gameRoot.appending(path: "archive/Mac/\(entry.path)")
        #expect(try Data(contentsOf: clone) == Data(contentsOf: live))
        #expect(try Hashes.sha256Hex(ofFileAt: clone) == entry.sha256)
    }
}

@Test func captureAloneDoesNotPublish() throws {
    let game = try TestGame()
    defer { game.cleanUp() }
    try seedTwoArchives(game)
    let store = BaselineStore(game: game.install)

    _ = try store.capture(gameVersion: "2.3.1", storefront: "heroic")

    #expect(store.publishedGeneration == nil)
    #expect(try store.publishedManifest() == nil)
}

@Test func publishingMakesTheGenerationReadable() throws {
    let game = try TestGame()
    defer { game.cleanUp() }
    try seedTwoArchives(game)
    let store = BaselineStore(game: game.install)

    let manifest = try store.capture(gameVersion: "2.3.1", storefront: "heroic")
    try store.publish(manifest)

    #expect(try store.publishedManifest() == manifest)
    #expect(store.publishedGeneration?.lastPathComponent == manifest.id)
}

@Test func anInterruptionMidCloneLeavesNothingPublished() throws {
    let game = try TestGame()
    defer { game.cleanUp() }
    try seedTwoArchives(game)
    let store = BaselineStore(game: game.install)

    var cloned = 0
    #expect(throws: StopHere.self) {
        _ = try store.capture(gameVersion: "2.3.1", storefront: "heroic", willClone: { _ in
            cloned += 1
            if cloned == 2 { throw StopHere() }
        })
    }

    #expect(store.publishedGeneration == nil)
    #expect(try store.publishedManifest() == nil)
}

@Test func anInterruptionAfterCloningButBeforeTheManifestLeavesNothingPublished() throws {
    let game = try TestGame()
    defer { game.cleanUp() }
    try seedTwoArchives(game)
    let store = BaselineStore(game: game.install)

    #expect(throws: StopHere.self) {
        _ = try store.capture(
            gameVersion: "2.3.1",
            storefront: "heroic",
            didCloneAll: { throw StopHere() }
        )
    }

    #expect(store.publishedGeneration == nil)
    #expect(try store.publishedManifest() == nil)
}

@Test func aFailedRecaptureLeavesThePreviousGenerationPublished() throws {
    let game = try TestGame()
    defer { game.cleanUp() }
    try seedTwoArchives(game)
    let store = BaselineStore(game: game.install)

    let first = try store.capture(gameVersion: "2.3.1", storefront: "heroic")
    try store.publish(first)

    #expect(throws: StopHere.self) {
        _ = try store.capture(
            gameVersion: "2.3.2",
            storefront: "heroic",
            didCloneAll: { throw StopHere() }
        )
    }

    // The whole point of a generation: a failed capture cannot cost you the
    // baseline you already had.
    #expect(try store.publishedManifest() == first)
    for entry in first.archives {
        let clone = store.generationDirectory(id: first.id).appending(path: entry.path)
        #expect(try Hashes.sha256Hex(ofFileAt: clone) == entry.sha256)
    }
}

@Test func publishingASecondGenerationRetiresTheFirst() throws {
    let game = try TestGame()
    defer { game.cleanUp() }
    try seedTwoArchives(game)
    let store = BaselineStore(game: game.install)

    let first = try store.capture(gameVersion: "2.3.1", storefront: "heroic")
    try store.publish(first)
    let second = try store.capture(gameVersion: "2.3.2", storefront: "heroic")
    try store.publish(second)

    #expect(try store.publishedManifest()?.id == second.id)
    // Generations are full-size once the live archives diverge from them, so
    // exactly one is kept.
    let remaining = try FileManager.default.contentsOfDirectory(
        atPath: game.install.baselinesDirectory.path
    ).sorted()
    #expect(remaining == [second.id])
}

@Test func captureRefusesAnInstallWithNoOfficialArchives() throws {
    let game = try TestGame()
    defer { game.cleanUp() }
    let store = BaselineStore(game: game.install)

    #expect(throws: BaselineError.self) {
        _ = try store.capture(gameVersion: "2.3.1", storefront: "heroic")
    }
}

@Test func sha256IsStreamedAndMatchesAKnownValue() throws {
    let work = FileManager.default.temporaryDirectory
        .appending(path: "archive-loader-sha-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    let file = work.appending(path: "abc.bin")
    try Data("abc".utf8).write(to: file)

    #expect(
        try Hashes.sha256Hex(ofFileAt: file)
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )

    // Larger than one read chunk, to prove the incremental path is wired up.
    let big = work.appending(path: "big.bin")
    try Data(repeating: 0x61, count: 9_000_000).write(to: big)
    #expect(try Hashes.sha256Hex(ofFileAt: big).count == 64)
}
