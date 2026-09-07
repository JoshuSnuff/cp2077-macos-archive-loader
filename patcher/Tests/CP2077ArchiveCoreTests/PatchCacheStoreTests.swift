import CP2077ArchiveCore
import Foundation
import Testing

private struct CacheFixture {
    let game: TestGame
    let store: PatchCacheStore
    let baseline: BaselineManifest
    let fingerprint: CacheFingerprint
    let engine: URL
    let loose: URL
    let stockEngine: Data

    var install: GameInstall { game.install }
}

private func cacheFixture() throws -> CacheFixture {
    let game = try TestGame()
    let engine = try game.writeOfficial("basegame_1_engine.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("stock".utf8))
    ])
    let baselineStore = BaselineStore(game: game.install)
    let baseline = try baselineStore.capture(gameVersion: "2.3.1", storefront: "heroic")
    try baselineStore.publish(baseline)
    let stockEngine = try Data(contentsOf: engine)

    // Stand in for what a patch run leaves behind.
    try Data("patched".utf8).write(to: engine)
    let loose = game.install.managedLooseArchive
    try Data("loose".utf8).write(to: loose)

    let fingerprint = try CacheFingerprint.compute(
        game: game.install,
        manifest: baseline,
        officialArchives: [engine],
        mods: []
    )
    return CacheFixture(
        game: game,
        store: PatchCacheStore(game: game.install),
        baseline: baseline,
        fingerprint: fingerprint,
        engine: engine,
        loose: loose,
        stockEngine: stockEngine
    )
}

@Test func anEmptyCacheMisses() throws {
    let f = try cacheFixture()
    defer { f.game.cleanUp() }

    #expect(try f.store.lookUp(f.fingerprint) == nil)
}

@Test func aStoredGenerationIsFoundAndRestoresTheExactBytes() throws {
    let f = try cacheFixture()
    defer { f.game.cleanUp() }

    let stored = try f.store.store(
        fingerprint: f.fingerprint,
        baseline: f.baseline,
        patchedArchives: [f.engine, f.loose],
        looseArchive: f.loose
    )
    #expect(stored.archives.count == 2)
    #expect(stored.looseArchive == "content/basegame_99_archive_loader.archive")

    // Wind the install back the way `run` does before applying a cache.
    try BaselineStore(game: f.install).restore()
    try FileManager.default.removeItem(at: f.loose)
    #expect(try Data(contentsOf: f.engine) == f.stockEngine)

    let manifest = try #require(try f.store.lookUp(f.fingerprint))
    let written = try f.store.apply(manifest, fingerprint: f.fingerprint)

    #expect(written.count == 2)
    #expect(try String(contentsOf: f.engine, encoding: .utf8) == "patched")
    #expect(try String(contentsOf: f.loose, encoding: .utf8) == "loose")
}

@Test func aDifferentFingerprintMisses() throws {
    let f = try cacheFixture()
    defer { f.game.cleanUp() }
    try f.store.store(
        fingerprint: f.fingerprint,
        baseline: f.baseline,
        patchedArchives: [f.engine],
        looseArchive: nil
    )

    let other = try CacheFingerprint.compute(
        game: f.install,
        manifest: BaselineManifest(
            id: "20260101T000000Z",
            capturedAt: f.baseline.capturedAt,
            gameVersion: f.baseline.gameVersion,
            storefront: f.baseline.storefront,
            loaderVersion: f.baseline.loaderVersion,
            archives: f.baseline.archives
        ),
        officialArchives: [f.engine],
        mods: []
    )
    #expect(try f.store.lookUp(other) == nil)
}

@Test func aGenerationMissingAFileMisses() throws {
    let f = try cacheFixture()
    defer { f.game.cleanUp() }
    try f.store.store(
        fingerprint: f.fingerprint,
        baseline: f.baseline,
        patchedArchives: [f.engine],
        looseArchive: nil
    )

    try FileManager.default.removeItem(
        at: f.store.generationDirectory(fingerprint: f.fingerprint)
            .appending(path: "content/basegame_1_engine.archive")
    )

    #expect(try f.store.lookUp(f.fingerprint) == nil)
}

@Test func aGenerationWhoseFileChangedSizeMisses() throws {
    let f = try cacheFixture()
    defer { f.game.cleanUp() }
    try f.store.store(
        fingerprint: f.fingerprint,
        baseline: f.baseline,
        patchedArchives: [f.engine],
        looseArchive: nil
    )

    try Data("a much longer replacement".utf8).write(
        to: f.store.generationDirectory(fingerprint: f.fingerprint)
            .appending(path: "content/basegame_1_engine.archive")
    )

    #expect(try f.store.lookUp(f.fingerprint) == nil)
}

@Test func aGenerationWhoseFileChangedWithoutChangingSizeIsVerifiedByPlan() throws {
    let f = try cacheFixture()
    defer { f.game.cleanUp() }
    try f.store.store(
        fingerprint: f.fingerprint,
        baseline: f.baseline,
        patchedArchives: [f.engine],
        looseArchive: nil
    )
    let cachedArchive = f.store.generationDirectory(fingerprint: f.fingerprint)
        .appending(path: "content/basegame_1_engine.archive")
    let originalSize = try Data(contentsOf: cachedArchive).count
    let replacement = Data(repeating: 0xa5, count: originalSize)
    try replacement.write(to: cachedArchive)

    #expect(try f.store.lookUp(f.fingerprint) != nil)
    #expect(try String(contentsOf: f.engine, encoding: .utf8) == "patched")
}

@Test func anIncompleteStagingDirectoryIsNeverFoundAndIsEvicted() throws {
    let f = try cacheFixture()
    defer { f.game.cleanUp() }

    let staging = f.install.cacheDirectory.appending(path: ".staging-abandoned", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

    try f.store.store(
        fingerprint: f.fingerprint,
        baseline: f.baseline,
        patchedArchives: [f.engine],
        looseArchive: nil
    )

    #expect(!FileManager.default.fileExists(atPath: staging.path))
    #expect(try f.store.lookUp(f.fingerprint) != nil)
}

@Test func evictionKeepsAtMostTheLimitIncludingThePublishedGeneration() throws {
    let f = try cacheFixture()
    defer { f.game.cleanUp() }
    let manager = FileManager.default
    try manager.createDirectory(at: f.install.cacheDirectory, withIntermediateDirectories: true)

    for name in ["older-a", "older-b"] {
        let generation = f.install.cacheDirectory.appending(path: name, directoryHint: .isDirectory)
        try manager.createDirectory(at: generation, withIntermediateDirectories: false)
        try manager.setAttributes(
            [.modificationDate: Date().addingTimeInterval(3_600)],
            ofItemAtPath: generation.path
        )
    }

    try f.store.store(
        fingerprint: f.fingerprint,
        baseline: f.baseline,
        patchedArchives: [f.engine],
        looseArchive: nil
    )

    let generations = try manager.contentsOfDirectory(
        at: f.install.cacheDirectory,
        includingPropertiesForKeys: nil
    )
    #expect(generations.count == PatchCacheStore.retainedGenerations)
    #expect(manager.fileExists(atPath: f.store.generationDirectory(fingerprint: f.fingerprint).path))
}

@Test func lookUpPropagatesUnreadableManifestErrors() throws {
    let f = try cacheFixture()
    defer { f.game.cleanUp() }
    let manifest = f.store.generationDirectory(fingerprint: f.fingerprint)
        .appending(path: "cache.json", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: true)

    #expect(throws: (any Error).self) {
        try f.store.lookUp(f.fingerprint)
    }
}

@Test func discardPropagatesNonNotFoundRemovalErrors() throws {
    let f = try cacheFixture()
    defer { f.game.cleanUp() }
    try FileManager.default.createDirectory(
        at: f.install.cacheDirectory.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("not a directory".utf8).write(to: f.install.cacheDirectory)

    #expect(throws: (any Error).self) {
        try f.store.discard(f.fingerprint)
    }
}

@Test func clearPropagatesNonNotFoundRemovalErrors() throws {
    let f = try cacheFixture()
    let manager = FileManager.default
    try manager.createDirectory(at: f.install.cacheDirectory, withIntermediateDirectories: true)
    try manager.setAttributes([.immutable: true], ofItemAtPath: f.install.cacheDirectory.path)
    defer {
        try? manager.setAttributes([.immutable: false], ofItemAtPath: f.install.cacheDirectory.path)
        f.game.cleanUp()
    }

    #expect(throws: (any Error).self) {
        try f.store.clear()
    }
}

@Test func storePublishesEvenWhenStagingEvictionFails() throws {
    let f = try cacheFixture()
    let manager = FileManager.default
    let abandoned = f.install.cacheDirectory
        .appending(path: ".staging-immutable", directoryHint: .isDirectory)
    try manager.createDirectory(at: abandoned, withIntermediateDirectories: true)
    try manager.setAttributes([.immutable: true], ofItemAtPath: abandoned.path)
    defer {
        try? manager.setAttributes([.immutable: false], ofItemAtPath: abandoned.path)
        f.game.cleanUp()
    }

    #expect(throws: Never.self) {
        try f.store.store(
            fingerprint: f.fingerprint,
            baseline: f.baseline,
            patchedArchives: [f.engine],
            looseArchive: nil
        )
    }
}

@Test func discardRemovesOneGenerationAndClearRemovesThemAll() throws {
    let f = try cacheFixture()
    defer { f.game.cleanUp() }
    try f.store.store(
        fingerprint: f.fingerprint,
        baseline: f.baseline,
        patchedArchives: [f.engine],
        looseArchive: nil
    )

    try f.store.discard(f.fingerprint)
    #expect(try f.store.lookUp(f.fingerprint) == nil)

    try f.store.store(
        fingerprint: f.fingerprint,
        baseline: f.baseline,
        patchedArchives: [f.engine],
        looseArchive: nil
    )
    try f.store.clear()
    #expect(try f.store.lookUp(f.fingerprint) == nil)
    #expect(!FileManager.default.fileExists(atPath: f.install.cacheDirectory.path))
}

/// A published baseline invalidates every generation keyed on the old one, so
/// publication is where the cache is dropped — it is the single commit point,
/// and three separate call sites would eventually miss one.
@Test func publishingABaselineClearsTheCache() throws {
    let f = try cacheFixture()
    defer { f.game.cleanUp() }
    try f.store.store(
        fingerprint: f.fingerprint,
        baseline: f.baseline,
        patchedArchives: [f.engine],
        looseArchive: nil
    )
    #expect(try f.store.lookUp(f.fingerprint) != nil)

    let baselineStore = BaselineStore(game: f.install)
    let recaptured = try baselineStore.capture(gameVersion: "2.3.1", storefront: "heroic")
    try baselineStore.publish(recaptured)

    #expect(!FileManager.default.fileExists(atPath: f.install.cacheDirectory.path))
}

@Test func theCacheDirectoryIsNotNegativeEvidence() throws {
    let f = try cacheFixture()
    defer { f.game.cleanUp() }
    try FileManager.default.removeItem(at: f.loose)
    try f.store.store(
        fingerprint: f.fingerprint,
        baseline: f.baseline,
        patchedArchives: [f.engine],
        looseArchive: nil
    )

    let findings = try NegativeEvidence.inspect(game: f.install).findings
    #expect(findings.allSatisfy { !$0.description.contains("/cache/") })
}

@Test func unsafeManifestPathsAreRejectedBeforeAnyClone() throws {
    let f = try cacheFixture()
    defer { f.game.cleanUp() }
    let stored = try f.store.store(
        fingerprint: f.fingerprint,
        baseline: f.baseline,
        patchedArchives: [f.engine],
        looseArchive: nil
    )
    try Data("live-before-apply".utf8).write(to: f.engine)

    let unsafeArchive = CacheManifest(
        fingerprint: stored.fingerprint,
        builtAt: stored.builtAt,
        patchFormat: stored.patchFormat,
        baselineGeneration: stored.baselineGeneration,
        gameVersion: stored.gameVersion,
        archives: stored.archives + [CachedArchive(
            path: "../../escaped.archive",
            size: 0
        )],
        looseArchive: nil
    )
    #expect(throws: PatchCacheError.self) {
        try f.store.apply(unsafeArchive, fingerprint: f.fingerprint)
    }
    #expect(try String(contentsOf: f.engine, encoding: .utf8) == "live-before-apply")

    let unsafeLoose = CacheManifest(
        fingerprint: stored.fingerprint,
        builtAt: stored.builtAt,
        patchFormat: stored.patchFormat,
        baselineGeneration: stored.baselineGeneration,
        gameVersion: stored.gameVersion,
        archives: stored.archives,
        looseArchive: "../escaped.archive"
    )
    #expect(throws: PatchCacheError.self) {
        try f.store.apply(unsafeLoose, fingerprint: f.fingerprint)
    }
    #expect(try String(contentsOf: f.engine, encoding: .utf8) == "live-before-apply")
}
