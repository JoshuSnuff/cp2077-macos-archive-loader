import CP2077ArchiveCore
import Foundation
import Testing

@Test func manifestWithoutTweaksStillDecodes() throws {
    let legacy = """
    {
      "id": "20260906T120448Z",
      "capturedAt": "2026-09-06T12:04:48Z",
      "gameVersion": "2.3.1",
      "storefront": "gog",
      "loaderVersion": "0.1.0",
      "archives": [
        {"path": "content/basegame_1_engine.archive", "size": 12, "sha256": "ab"}
      ]
    }
    """
    let manifest = try JSONDecoder().decode(BaselineManifest.self, from: Data(legacy.utf8))

    #expect(manifest.archives.count == 1)
    #expect(manifest.tweaks.isEmpty)
}

@Test func manifestRoundTripsTheTweaksArray() throws {
    let manifest = BaselineManifest(
        id: "20260911T000000Z",
        capturedAt: "2026-09-11T00:00:00Z",
        gameVersion: "2.3.1",
        storefront: "gog",
        loaderVersion: "0.1.0",
        archives: [],
        tweaks: [BaselineEntry(path: "r6/cache/tweakdb.bin", size: 42_028_033, sha256: "cd")]
    )
    let encoded = try JSONEncoder().encode(manifest)
    let decoded = try JSONDecoder().decode(BaselineManifest.self, from: encoded)

    #expect(decoded.tweaks.first?.path == "r6/cache/tweakdb.bin")
    #expect(decoded.tweaks.first?.size == 42_028_033)
}

@Test func tweakPathsAreRelativeToTheGameRoot() throws {
    let root = URL(fileURLWithPath: "/tmp/game", isDirectory: true)
    let game = GameInstall(root: root)

    #expect(game.tweakCacheDirectory.lastPathComponent == "cache")
    #expect(game.tweakModsDirectory.path.hasSuffix("archive-loader/mods/tweaks"))
    #expect(game.tweakCacheRoot.path.hasSuffix("archive-loader/cache/tweaks"))

    let blob = root.appending(path: "r6/cache/tweakdb.bin")
    #expect(BaselineStore.relativeTweakPath(blob, game: game) == "r6/cache/tweakdb.bin")
}

@Test(arguments: [
    "../r6/cache/tweakdb.bin",
    "r6/cache/../tweakdb.bin",
    "/tmp/tweakdb.bin",
    "r6/cache/other.bin",
    "r6/cache/tweakdb.bin/child",
])
func manifestRejectsNonAllowlistedTweakPaths(_ path: String) throws {
    let json = """
    {
      "id": "id",
      "capturedAt": "now",
      "gameVersion": "2.3.1",
      "storefront": "gog",
      "loaderVersion": "0.1.0",
      "archives": [],
      "tweaks": [{"path": "\(path)", "size": 1, "sha256": "aa"}]
    }
    """

    #expect(throws: BaselineError.self) {
        _ = try JSONDecoder().decode(BaselineManifest.self, from: Data(json.utf8))
    }
}

@Test func manifestRejectsDuplicateTweakPaths() throws {
    let json = """
    {
      "id": "id",
      "capturedAt": "now",
      "gameVersion": "2.3.1",
      "storefront": "gog",
      "loaderVersion": "0.1.0",
      "archives": [],
      "tweaks": [
        {"path": "r6/cache/tweakdb.bin", "size": 1, "sha256": "aa"},
        {"path": "r6/cache/tweakdb.bin", "size": 1, "sha256": "aa"}
      ]
    }
    """

    #expect(throws: BaselineError.self) {
        _ = try JSONDecoder().decode(BaselineManifest.self, from: Data(json.utf8))
    }
}

@Test func manifestValidationRejectsAnEntryThatEscapesItsGameRoot() throws {
    let game = GameInstall(root: URL(fileURLWithPath: "/tmp/game", isDirectory: true))
    let escaped = URL(fileURLWithPath: "/tmp/outside/tweakdb.bin")

    #expect(throws: BaselineError.self) {
        try BaselineStore.validateTweakURL(escaped, game: game)
    }
}
