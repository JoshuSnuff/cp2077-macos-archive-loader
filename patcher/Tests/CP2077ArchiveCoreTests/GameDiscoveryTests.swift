import CP2077ArchiveCore
import Foundation
import Testing

private struct DiscoveryFixture {
    let root: URL
    let home: URL
    let steam: URL
    let gogApplications: URL
    let heroic: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "patcher-discovery-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        home = root.appending(path: "Home", directoryHint: .isDirectory)
        steam = home.appending(path: "Library/Application Support/Steam", directoryHint: .isDirectory)
        gogApplications = home.appending(
            path: "Library/Application Support/GOG.com/Galaxy/Applications",
            directoryHint: .isDirectory
        )
        heroic = home.appending(path: "Library/Application Support/heroic", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func locations(
        conventional: [URL] = [],
        bounded: [URL] = [],
        maximumSearchDepth: Int = 4
    ) -> GameDiscoveryLocations {
        GameDiscoveryLocations(
            homeDirectory: home,
            steamRoot: steam,
            gogApplicationsDirectory: gogApplications,
            heroicDataDirectories: [heroic],
            conventionalCandidates: conventional,
            boundedSearchRoots: bounded,
            maximumSearchDepth: maximumSearchDepth
        )
    }

    @discardableResult
    func makeGame(at gameRoot: URL, version: String = "2.31a") throws -> URL {
        let executable = gameRoot.appending(path: "Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077")
        let infoPlist = gameRoot.appending(path: "Cyberpunk2077.app/Contents/Info.plist")
        let content = gameRoot.appending(path: "archive/Mac/content", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try Data("fixture executable".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: executable.path
        )
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": version],
            format: .xml,
            options: 0
        )
        try plist.write(to: infoPlist)
        try Data("fixture archive".utf8).write(to: content.appending(path: "basegame_1_fixture.archive"))
        return gameRoot.normalizedFileURL
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Test func discoversHeroicCustomPathWithSpaces() throws {
    let fixture = try DiscoveryFixture()
    defer { fixture.cleanUp() }
    let game = try fixture.makeGame(
        at: fixture.root.appending(path: "External Games/Heroic/Cyberpunk 2077", directoryHint: .isDirectory)
    )
    let metadata = fixture.heroic.appending(path: "gog_store/installed.json")
    try FileManager.default.createDirectory(at: metadata.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: [
        "installed": [[
            "platform": "osx",
            "install_path": game.path,
            "appName": "1423049311",
        ]]
    ])
    try data.write(to: metadata)

    let candidates = GameDiscovery.discover(locations: fixture.locations())

    #expect(candidates.count == 1)
    #expect(candidates[0].root == game)
    #expect(candidates[0].version == "2.31a")
    #expect(candidates[0].sources == ["heroic"])
}

@Test func discoversSteamLibraryManifest() throws {
    let fixture = try DiscoveryFixture()
    defer { fixture.cleanUp() }
    let library = fixture.root.appending(path: "A Steam Library", directoryHint: .isDirectory)
    let game = try fixture.makeGame(
        at: library.appending(path: "steamapps/common/Custom Cyberpunk", directoryHint: .isDirectory),
        version: "2.3.1"
    )
    let libraryFile = fixture.steam.appending(path: "steamapps/libraryfolders.vdf")
    try FileManager.default.createDirectory(at: libraryFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("\"libraryfolders\" { \"0\" { \"path\" \"\(library.path)\" } }".utf8).write(to: libraryFile)
    let manifest = library.appending(path: "steamapps/appmanifest_1091500.acf")
    try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("\"AppState\" { \"appid\" \"1091500\" \"installdir\" \"Custom Cyberpunk\" }".utf8)
        .write(to: manifest)

    let candidates = GameDiscovery.discover(locations: fixture.locations())

    #expect(candidates.count == 1)
    #expect(candidates[0].root == game)
    #expect(candidates[0].sources == ["steam"])
}

@Test func discoversGOGRegisteredApplicationAndResolvesSymlink() throws {
    let fixture = try DiscoveryFixture()
    defer { fixture.cleanUp() }
    let game = try fixture.makeGame(
        at: fixture.root.appending(path: "GOG Games/Cyberpunk 2077", directoryHint: .isDirectory)
    )
    try FileManager.default.createDirectory(at: fixture.gogApplications, withIntermediateDirectories: true)
    let registration = fixture.gogApplications.appending(path: "1423049311")
    try FileManager.default.createSymbolicLink(at: registration, withDestinationURL: game)

    let candidates = GameDiscovery.discover(locations: fixture.locations(conventional: [game]))

    #expect(candidates.count == 1)
    #expect(candidates[0].root == game)
    #expect(candidates[0].sources == ["conventional", "gog"])
}

@Test func boundedSearchFindsNestedGameWithoutScanningPastLimit() throws {
    let fixture = try DiscoveryFixture()
    defer { fixture.cleanUp() }
    let searchRoot = fixture.root.appending(path: "Search", directoryHint: .isDirectory)
    let game = try fixture.makeGame(
        at: searchRoot.appending(path: "Vendor/Games/Cyberpunk 2077", directoryHint: .isDirectory)
    )
    _ = try fixture.makeGame(
        at: searchRoot.appending(path: "Too/Deep/For/Search/Cyberpunk 2077", directoryHint: .isDirectory)
    )

    let candidates = GameDiscovery.discover(
        locations: fixture.locations(bounded: [searchRoot], maximumSearchDepth: 3)
    )

    #expect(candidates.map(\.root) == [game])
    #expect(candidates.first?.sources == ["bounded-search"])
}

@Test func discoveryReturnsMultipleInstallsInCanonicalPathOrder() throws {
    let fixture = try DiscoveryFixture()
    defer { fixture.cleanUp() }
    let second = try fixture.makeGame(at: fixture.root.appending(path: "Games/Z Game", directoryHint: .isDirectory))
    let first = try fixture.makeGame(at: fixture.root.appending(path: "Games/A Game", directoryHint: .isDirectory))

    let candidates = GameDiscovery.discover(locations: fixture.locations(conventional: [second, first]))

    #expect(candidates.map(\.root) == [first, second])
}

@Test func invalidCandidatesAreRejected() throws {
    let fixture = try DiscoveryFixture()
    defer { fixture.cleanUp() }
    let invalid = fixture.root.appending(path: "Not A Game", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: invalid.appending(path: "Cyberpunk2077.app", directoryHint: .isDirectory),
        withIntermediateDirectories: true
    )

    #expect(GameDiscovery.discover(locations: fixture.locations(conventional: [invalid])).isEmpty)
    #expect(throws: GameValidationError.self) {
        try GameDiscovery.validate(root: invalid)
    }
}

@Test func explicitAndEnvironmentSelectionTakePrecedence() throws {
    let fixture = try DiscoveryFixture()
    defer { fixture.cleanUp() }
    let explicit = try fixture.makeGame(at: fixture.root.appending(path: "Explicit Game", directoryHint: .isDirectory))
    let environment = try fixture.makeGame(
        at: fixture.root.appending(path: "Environment Game", directoryHint: .isDirectory)
    )

    let explicitResult = try GameDiscovery.resolve(
        explicitRoot: explicit.appending(path: "Cyberpunk2077.app", directoryHint: .isDirectory),
        environment: ["ARCHIVE_LOADER_GAME_DIR": environment.path],
        installedExecutable: nil,
        locations: fixture.locations(conventional: [environment])
    )
    let environmentResult = try GameDiscovery.resolve(
        environment: ["ARCHIVE_LOADER_GAME_DIR": environment.path],
        installedExecutable: nil,
        locations: fixture.locations(conventional: [explicit])
    )

    #expect(explicitResult.map(\.root) == [explicit])
    #expect(explicitResult[0].sources == ["explicit"])
    #expect(environmentResult.map(\.root) == [environment])
    #expect(environmentResult[0].sources == ["environment"])
}

@Test func gameRootIsTwoDirectoriesAboveTheInstalledBinary() {
    let executable = URL(fileURLWithPath: "/games/Cyberpunk 2077/archive-loader/bin/archive-loader")

    #expect(
        InstalledLayout.gameRoot(forExecutable: executable).path
            == "/games/Cyberpunk 2077"
    )
}

@Test func installedBinaryResolvesItsOwnGameRoot() throws {
    let fixture = try DiscoveryFixture()
    defer { fixture.cleanUp() }
    let game = try fixture.makeGame(at: fixture.root.appending(path: "Installed Game", directoryHint: .isDirectory))
    let executable = game.appending(path: "archive-loader/bin/archive-loader")
    try FileManager.default.createDirectory(
        at: executable.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("fixture binary".utf8).write(to: executable)

    let resolved = try GameDiscovery.resolve(
        environment: [:],
        installedExecutable: executable,
        locations: fixture.locations()
    )

    #expect(resolved.map(\.root) == [game])
    #expect(resolved[0].sources == ["installed"])
}

@Test func explicitAndEnvironmentOutrankTheInstalledLocation() throws {
    let fixture = try DiscoveryFixture()
    defer { fixture.cleanUp() }
    let explicit = try fixture.makeGame(at: fixture.root.appending(path: "Explicit", directoryHint: .isDirectory))
    let environment = try fixture.makeGame(at: fixture.root.appending(path: "Environment", directoryHint: .isDirectory))
    let installed = try fixture.makeGame(at: fixture.root.appending(path: "Installed", directoryHint: .isDirectory))
    let executable = installed.appending(path: "archive-loader/bin/archive-loader")
    try FileManager.default.createDirectory(
        at: executable.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("fixture binary".utf8).write(to: executable)

    let explicitResult = try GameDiscovery.resolve(
        explicitRoot: explicit,
        environment: ["ARCHIVE_LOADER_GAME_DIR": environment.path],
        installedExecutable: executable,
        locations: fixture.locations()
    )
    let environmentResult = try GameDiscovery.resolve(
        environment: ["ARCHIVE_LOADER_GAME_DIR": environment.path],
        installedExecutable: executable,
        locations: fixture.locations()
    )

    #expect(explicitResult.map(\.root) == [explicit])
    #expect(environmentResult.map(\.root) == [environment])
}

@Test func aDevelopmentBuildFallsThroughToDiscovery() throws {
    let fixture = try DiscoveryFixture()
    defer { fixture.cleanUp() }
    let game = try fixture.makeGame(at: fixture.root.appending(path: "Discovered Game", directoryHint: .isDirectory))
    // A development build lives in .build/release, whose grandparent is the
    // package directory, not a game. Resolution must not abort on that.
    let executable = fixture.root.appending(path: "checkout/.build/release/archive-loader")
    try FileManager.default.createDirectory(
        at: executable.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("fixture binary".utf8).write(to: executable)

    let resolved = try GameDiscovery.resolve(
        environment: [:],
        installedExecutable: executable,
        locations: fixture.locations(conventional: [game])
    )

    #expect(resolved.map(\.root) == [game])
    #expect(resolved[0].sources == ["conventional"])
}
