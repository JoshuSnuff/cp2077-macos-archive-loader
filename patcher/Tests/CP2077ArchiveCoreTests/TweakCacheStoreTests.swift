import CP2077ArchiveCore
import Foundation
import Testing

@Test func tweakFingerprintIncludesBaselineModsFormatLoaderAndInventory() throws {
    let game = try TestGame()
    defer { game.cleanUp() }
    let mods = game.install.tweakModsDirectory
    try FileManager.default.createDirectory(at: mods, withIntermediateDirectories: true)
    let mod = mods.appending(path: "a.yaml")
    try Data("Items.Widget:\n  power: 1\n".utf8).write(to: mod)

    let manifest = BaselineManifest(
        id: "generation",
        capturedAt: "now",
        gameVersion: "2.3.1",
        storefront: "gog",
        loaderVersion: LoaderVersion.current,
        archives: [],
        tweaks: [BaselineEntry(path: "r6/cache/tweakdb.bin", size: 3, sha256: "baseline-a")]
    )
    let inventory = ArchiveXLInventory(matches: [
        ArchiveXLMatch(path: "/game/red4ext/plugins/ArchiveXL.dylib", reason: "fixture")
    ])
    let before = try TweakFingerprint.compute(
        game: game.install, manifest: manifest, mods: [mod], inventory: inventory
    )

    try Data("Items.Widget:\n  power: 2\n".utf8).write(to: mod)
    let afterMod = try TweakFingerprint.compute(
        game: game.install, manifest: manifest, mods: [mod], inventory: inventory
    )
    let afterInventory = try TweakFingerprint.compute(
        game: game.install, manifest: manifest, mods: [mod],
        inventory: ArchiveXLInventory(matches: [])
    )

    #expect(before.value != afterMod.value)
    #expect(before.value != afterInventory.value)
    #expect(before.canonicalInput.contains("loaderVersion \(LoaderVersion.current)"))
    #expect(before.canonicalInput.contains("tweakFormat \(TweakFormat.current)"))
    #expect(before.canonicalInput.contains("baseline-a"))
    #expect(before.canonicalInput.contains(ArchiveXLInventory.inventorySchema))

    let changedBaseline = BaselineManifest(
        id: manifest.id,
        capturedAt: manifest.capturedAt,
        gameVersion: manifest.gameVersion,
        storefront: manifest.storefront,
        loaderVersion: manifest.loaderVersion,
        archives: manifest.archives,
        tweaks: [BaselineEntry(path: "r6/cache/tweakdb.bin", size: 3, sha256: "baseline-b")]
    )
    let afterBaseline = try TweakFingerprint.compute(
        game: game.install, manifest: changedBaseline, mods: [mod], inventory: inventory
    )
    #expect(before.value != afterBaseline.value)
}

@Test func tweakCacheStoresAndClearsCompleteGenerations() throws {
    let game = try TestGame()
    defer { game.cleanUp() }
    let store = TweakCacheStore(game: game.install)
    let fingerprint = CacheFingerprint(value: "deadbeef", canonicalInput: "canonical")
    let source = game.root.appending(path: "tweakdb.bin")
    try Data("built".utf8).write(to: source)

    try store.store([source], for: fingerprint)
    #expect(store.isCurrent(fingerprint))
    #expect(store.installedBlobs(for: fingerprint).map(\.lastPathComponent) == ["tweakdb.bin"])

    try store.clear()
    #expect(!store.isCurrent(fingerprint))
}
