import CP2077ArchiveCore
import Foundation
import Testing

@Test func everyBackupInARunGetsItsOwnDirectoryAndManifest() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    // A grouped run backs up every target archive within the same second, so a
    // second-resolution id with a random suffix collides often enough to matter:
    // the loser's manifest is overwritten and its archive can never be restored.
    // 500 draws from 9000 suffixes makes a collision a near-certainty rather
    // than the coin-flip a run-sized 47 would be.
    var archives: [URL] = []
    for i in 0..<500 {
        archives.append(try game.writeOfficial("basegame_\(i)_stock.archive", records: [
            TestRecord(hash: UInt64(0x1000 + i), payload: Data("stock-\(i)".utf8))
        ]))
    }

    let store = BackupStore(game: game.install)
    for archive in archives {
        _ = try store.createBackup(targetArchive: archive, sourceArchive: nil, note: "test")
    }

    let directories = try FileManager.default.contentsOfDirectory(
        at: game.install.backupDirectory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    )
    #expect(directories.count == archives.count)

    let manifests = directories.filter {
        FileManager.default.fileExists(atPath: $0.appending(path: "manifest.json").path)
    }
    #expect(manifests.count == archives.count)

    // Every original must be individually restorable.
    let restored = try directories.map { try store.restore(backupDirectory: $0) }
    #expect(Set(restored.map(\.lastPathComponent)).count == archives.count)
}
