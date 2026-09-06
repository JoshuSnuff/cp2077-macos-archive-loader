import CP2077ArchiveCore
import Foundation
import Testing

@Test func aCleanInstallProducesNoFindings() throws {
    let game = try TestGame()
    defer { game.cleanUp() }
    try game.writeOfficial("basegame_1_engine.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("stock".utf8))
    ])
    try game.writeEP1("ep1_1_main.archive", records: [
        TestRecord(hash: 0x2222, payload: Data("stock".utf8))
    ])

    let evidence = try NegativeEvidence.inspect(game: game.install)

    #expect(evidence.isClean)
    #expect(evidence.findings.isEmpty)
}

@Test func aLooseArchiveInContentIsRefused() throws {
    let game = try TestGame()
    defer { game.cleanUp() }
    let loose = try game.seed(relativePath: "archive/Mac/content/basegame_99_something.archive")

    let evidence = try NegativeEvidence.inspect(game: game.install)

    #expect(!evidence.isClean)
    #expect(evidence.findings == [.looseArchive(loose.normalizedFileURL)])
}

@Test func aLooseArchiveInEP1IsRefused() throws {
    let game = try TestGame()
    defer { game.cleanUp() }
    let loose = try game.seed(relativePath: "archive/Mac/ep1/basegame_99_something.archive")

    let evidence = try NegativeEvidence.inspect(game: game.install)

    #expect(evidence.findings == [.looseArchive(loose.normalizedFileURL)])
}

@Test func theModStagingDirectoryIsRefused() throws {
    let game = try TestGame()
    defer { game.cleanUp() }
    try game.seed(relativePath: "archive/Mac/mod", isDirectory: true)

    let evidence = try NegativeEvidence.inspect(game: game.install)

    #expect(evidence.findings == [.modStagingDirectory(game.install.modStagingDirectory.normalizedFileURL)])
}

@Test func bothLegacyBackupDirectoriesAreRefused() throws {
    let game = try TestGame()
    defer { game.cleanUp() }
    try game.seed(relativePath: "archive/Mac/_patcher", isDirectory: true)
    try game.seed(relativePath: "archive/Mac/_cp2077_mac_patcher", isDirectory: true)

    let evidence = try NegativeEvidence.inspect(game: game.install)

    #expect(evidence.findings.count == 2)
    #expect(evidence.findings.allSatisfy {
        if case .legacyBackupDirectory = $0 { return true }
        return false
    })
}

@Test func anAlreadyPublishedBaselineIsRefused() throws {
    let game = try TestGame()
    defer { game.cleanUp() }
    let generation = game.install.baselinesDirectory.appending(path: "20260906T000000Z", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: generation, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: game.install.pristinePointer, withDestinationURL: generation)

    let evidence = try NegativeEvidence.inspect(game: game.install)

    #expect(evidence.findings == [.publishedBaseline(game.install.pristinePointer)])
}

@Test func aForeignHandInstalledModIsStillEvidenceButNeverDeleted() throws {
    let game = try TestGame()
    defer { game.cleanUp() }
    let foreign = try game.seed(relativePath: "archive/Mac/content/basegame_99_usermod.archive")

    let evidence = try NegativeEvidence.inspect(game: game.install)

    #expect(!evidence.isClean)
    // Inspecting must be pure: the gate refuses, and something else decides
    // what to do about it. basegame_99_ is the documented way to hand-install
    // a new-content mod, so a user may well own this file.
    #expect(FileManager.default.fileExists(atPath: foreign.path))
}

@Test func everyFindingExplainsItselfInTheSummary() throws {
    let game = try TestGame()
    defer { game.cleanUp() }
    try game.seed(relativePath: "archive/Mac/mod", isDirectory: true)
    try game.seed(relativePath: "archive/Mac/content/basegame_99_something.archive")

    let evidence = try NegativeEvidence.inspect(game: game.install)

    #expect(evidence.findings.count == 2)
    for finding in evidence.findings {
        #expect(evidence.summary.contains(finding.description))
    }
}
