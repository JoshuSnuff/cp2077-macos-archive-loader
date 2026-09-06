import CP2077ArchiveCore
import Foundation
import Testing

@Test func everyBackupInARunGetsItsOwnDirectoryAndManifest() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    // Archive directories are derived from target names, so even 500 backups
    // created in one second remain distinct and individually restorable.
    var archives: [URL] = []
    for i in 0..<500 {
        archives.append(try game.writeOfficial("basegame_\(i)_stock.archive", records: [
            TestRecord(hash: UInt64(0x1000 + i), payload: Data("stock-\(i)".utf8))
        ]))
    }

    let store = BackupStore(game: game.install)
    let run = try store.beginRun(plan: emptyPlan())
    let directories = try archives.map { try run.backup(targetArchive: $0, note: "test") }
    try run.complete()

    #expect(directories.count == archives.count)
    #expect(FileManager.default.fileExists(atPath: run.directory.appending(path: "run.json").path))
    let manifests = directories.filter {
        FileManager.default.fileExists(atPath: $0.appending(path: "manifest.json").path)
    }
    #expect(manifests.count == archives.count)

    for archive in archives {
        try Data("changed".utf8).write(to: archive)
    }
    let restored = try directories.flatMap { try store.restore(backupDirectory: $0) }
    #expect(Set(restored.map(\.lastPathComponent)).count == archives.count)
}

@Test func patchGroupsSeveralArchivesIntoOneCompletedRun() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    _ = try game.writeOfficial("basegame_1_a.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("stock-a".utf8))
    ])
    _ = try game.writeOfficial("basegame_2_b.archive", records: [
        TestRecord(hash: 0x2222, payload: Data("stock-b".utf8))
    ])
    let mod = try game.writeMod("mod.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("mod-a".utf8)),
        TestRecord(hash: 0x2222, payload: Data("mod-b".utf8))
    ])

    let plan = try PatchPlanner.plan(mods: [mod], game: game.install)
    _ = try RDARPatcher(game: game.install).apply(plan: plan)

    let runs = try backupRuns(in: game)
    let run = try #require(runs.first)
    let manifest = try decodeRun(run)
    #expect(runs.count == 1)
    #expect(manifest.completed)
    #expect(manifest.archives.count == 2)
    #expect(Set(manifest.archives.map(\.directory)) == ["basegame_1_a.archive", "basegame_2_b.archive"])
}

@Test func restoreLatestRestoresEveryArchiveInTheRun() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let first = try game.writeOfficial("basegame_1_a.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("stock-a".utf8))
    ])
    let second = try game.writeOfficial("basegame_2_b.archive", records: [
        TestRecord(hash: 0x2222, payload: Data("stock-b".utf8))
    ])
    let originals = try [first: Data(contentsOf: first), second: Data(contentsOf: second)]
    let mod = try game.writeMod("mod.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("mod-a".utf8)),
        TestRecord(hash: 0x2222, payload: Data("mod-b".utf8))
    ])

    let plan = try PatchPlanner.plan(mods: [mod], game: game.install)
    _ = try RDARPatcher(game: game.install).apply(plan: plan)
    let restored = try BackupStore(game: game.install).restoreLatest()

    #expect(Set(restored) == Set([first, second]))
    #expect(try Data(contentsOf: first) == originals[first])
    #expect(try Data(contentsOf: second) == originals[second])
}

@Test func incompleteRunIsRefusedWithoutTouchingAnyArchive() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let first = try game.writeOfficial("basegame_1_a.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("stock-a".utf8))
    ])
    let second = try game.writeOfficial("basegame_2_b.archive", records: [
        TestRecord(hash: 0x2222, payload: Data("stock-b".utf8))
    ])
    let store = BackupStore(game: game.install)
    let run = try store.beginRun(plan: emptyPlan())
    _ = try run.backup(targetArchive: first, note: "test")
    _ = try run.backup(targetArchive: second, note: "test")

    let changedFirst = Data("changed-a".utf8)
    let changedSecond = Data("changed-b".utf8)
    try changedFirst.write(to: first)
    try changedSecond.write(to: second)

    #expect(throws: BackupStoreError.self) {
        _ = try store.restoreLatest()
    }
    #expect(try Data(contentsOf: first) == changedFirst)
    #expect(try Data(contentsOf: second) == changedSecond)
}

@Test func missingBackupAbortsBeforeWritingAnyArchive() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let first = try game.writeOfficial("basegame_1_a.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("stock-a".utf8))
    ])
    let second = try game.writeOfficial("basegame_2_b.archive", records: [
        TestRecord(hash: 0x2222, payload: Data("stock-b".utf8))
    ])
    let store = BackupStore(game: game.install)
    let run = try store.beginRun(plan: emptyPlan())
    _ = try run.backup(targetArchive: first, note: "test")
    let secondBackup = try run.backup(targetArchive: second, note: "test")
    try run.complete()

    let changedFirst = Data("changed-a".utf8)
    let changedSecond = Data("changed-b".utf8)
    try changedFirst.write(to: first)
    try changedSecond.write(to: second)
    try FileManager.default.removeItem(at: secondBackup.appending(path: second.lastPathComponent))

    #expect(throws: BackupStoreError.self) {
        _ = try store.restoreLatest()
    }
    #expect(try Data(contentsOf: first) == changedFirst)
    #expect(try Data(contentsOf: second) == changedSecond)
}

@Test func truncatedBackupAbortsBeforeWritingAnyArchive() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let first = try game.writeOfficial("basegame_1_a.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("stock-a".utf8))
    ])
    let second = try game.writeOfficial("basegame_2_b.archive", records: [
        TestRecord(hash: 0x2222, payload: Data("stock-b".utf8))
    ])
    let store = BackupStore(game: game.install)
    let run = try store.beginRun(plan: emptyPlan())
    _ = try run.backup(targetArchive: first, note: "test")
    let secondBackup = try run.backup(targetArchive: second, note: "test")
    try run.complete()

    let changedFirst = Data("changed-a".utf8)
    let changedSecond = Data("changed-b".utf8)
    try changedFirst.write(to: first)
    try changedSecond.write(to: second)
    try Data("short".utf8).write(to: secondBackup.appending(path: second.lastPathComponent))

    #expect(throws: BackupStoreError.self) {
        _ = try store.restoreLatest()
    }
    #expect(try Data(contentsOf: first) == changedFirst)
    #expect(try Data(contentsOf: second) == changedSecond)
}

@Test func individualArchiveRestoreStillWorksForAnIncompleteRun() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let archive = try game.writeOfficial("basegame_1_a.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("stock".utf8))
    ])
    let original = try Data(contentsOf: archive)
    let store = BackupStore(game: game.install)
    let run = try store.beginRun(plan: emptyPlan())
    let archiveBackup = try run.backup(targetArchive: archive, note: "test")
    try Data("changed".utf8).write(to: archive)

    let restored = try store.restore(backupDirectory: archiveBackup)
    #expect(restored == [archive])
    #expect(try Data(contentsOf: archive) == original)
}

@Test func pruningKeepsNewestCompletedRunAndSupportsDryRun() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let store = BackupStore(game: game.install)
    var runs: [URL] = []
    for _ in 0..<3 {
        let run = try store.beginRun(plan: emptyPlan())
        try run.complete()
        runs.append(run.directory)
    }

    let dryRun = try store.prune(keep: 1, dryRun: true)
    #expect(dryRun == Array(runs.prefix(2)))
    #expect(try backupRuns(in: game).count == 3)

    let removed = try store.prune(keep: 1)
    #expect(removed == Array(runs.prefix(2)))
    #expect(try backupRuns(in: game) == [runs[2]])

    #expect(try store.prune(keep: 0).isEmpty)
    #expect(try backupRuns(in: game) == [runs[2]])
}

@Test func pruningRemovesIncompleteRunsOlderThanNewestCompletedRun() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let store = BackupStore(game: game.install)
    let incomplete = try store.beginRun(plan: emptyPlan())
    let complete = try store.beginRun(plan: emptyPlan())
    try complete.complete()

    let removed = try store.prune(keep: 3)
    #expect(removed == [incomplete.directory])
    #expect(try backupRuns(in: game) == [complete.directory])
}

@Test func runManifestListsEveryModInAsciiOrder() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let first = try game.writeMod("#first.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("first".utf8))
    ])
    let second = try game.writeMod("z_second.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("second".utf8))
    ])
    let plan = try PatchPlanner.plan(mods: [second, first], officialArchives: [])
    let run = try BackupStore(game: game.install).beginRun(plan: plan)
    let manifest = try decodeRun(run.directory)

    #expect(manifest.mods == [first.path, second.path])
    #expect(manifest.planSummary.winners == 1)
    #expect(manifest.planSummary.overrides == 0)
    #expect(manifest.planSummary.newResources == 1)
    #expect(manifest.planSummary.conflicts == 1)
}

@Test func backupsLiveInTheLoaderDirectoryNotTheArchiveTree() throws {
    let game = GameInstall(root: URL(fileURLWithPath: "/games/Cyberpunk 2077", isDirectory: true))

    #expect(game.loaderDirectory.path == "/games/Cyberpunk 2077/archive-loader")
    #expect(game.backupDirectory.path == "/games/Cyberpunk 2077/archive-loader/backups")
    // Phase 2's negative-evidence gate reads a directory inside archive/Mac as
    // proof of a pre-0.1 session. That inference is only sound while 0.1 writes
    // nothing there itself.
    #expect(!game.backupDirectory.path.contains("/archive/Mac/"))
    #expect(
        game.legacyPatcherDirectories.map(\.lastPathComponent)
            == ["_patcher", "_cp2077_mac_patcher"]
    )
}

@Test func aBackupRunLandsOutsideTheArchiveDirectories() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    _ = try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: 0x9001, payload: Data("stock".utf8))
    ])

    let store = BackupStore(game: game.install)
    let run = try store.beginRun(plan: emptyPlan())
    _ = try run.backup(targetArchive: game.contentDirectory.appending(path: "basegame_1_stock.archive"))
    try run.complete()

    // Both sides are normalized because beginRun normalizes the directory it
    // returns while GameInstall keeps the caller's spelling, and the fixture
    // root sits under /var, which resolves to /private/var. The existing
    // BackupStoreTests carry the same workaround at :257-261.
    #expect(
        run.directory.normalizedFileURL.path
            .hasPrefix(game.install.loaderDirectory.normalizedFileURL.path)
    )
    // macArchives enumerates archive/Mac only, so a backup copy of an official
    // archive can no longer be mistaken for an official archive.
    let enumerated = try game.install.macArchives().map(\.lastPathComponent)
    #expect(enumerated == ["basegame_1_stock.archive"])
}

private func emptyPlan() -> PatchPlan {
    PatchPlan(winners: [:], officialWork: [:], newResources: [], losers: [])
}

private func backupRuns(in game: TestGame) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
        at: game.install.backupDirectory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ).filter { $0.hasDirectoryPath }.map {
        game.install.backupDirectory.appending(path: $0.lastPathComponent, directoryHint: .isDirectory)
    }.sorted { $0.lastPathComponent < $1.lastPathComponent }
}

private func decodeRun(_ directory: URL) throws -> RunManifest {
    try JSONDecoder().decode(RunManifest.self, from: Data(contentsOf: directory.appending(path: "run.json")))
}
