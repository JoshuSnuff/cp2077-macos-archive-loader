import CP2077ArchiveCore
import Foundation
import Testing

@Test func fnvKnownDepotPath() {
    #expect(Hashes.fnv1a64Path("base\\characters\\appearances\\main_npc\\example.app") == 0xcb69df8a62b2314b)
}

@Test func patchPreservesUnrelatedDuplicateTargetHashes() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "cp2077-patcher-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let gameRoot = root.appending(path: "Game", directoryHint: .isDirectory)
    let contentDir = gameRoot.appending(path: "archive/Mac/content", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: contentDir, withIntermediateDirectories: true)

    let requestedHash: UInt64 = 0x8114580bd0addf7e
    let duplicateHash: UInt64 = 0x00cc12486e7d5d9f
    let sourceArchive = root.appending(path: "source.archive")
    let targetArchive = contentDir.appending(path: "basegame_3_test.archive")

    try writeTestArchive(
        to: sourceArchive,
        records: [
            TestRecord(hash: requestedHash, payload: Data("replacement".utf8))
        ]
    )
    try writeTestArchive(
        to: targetArchive,
        records: [
            TestRecord(hash: duplicateHash, payload: Data("duplicate-a".utf8)),
            TestRecord(hash: duplicateHash, payload: Data("duplicate-b".utf8)),
            TestRecord(hash: requestedHash, payload: Data("original".utf8))
        ]
    )

    let summary = try RDARPatcher(game: GameInstall(root: gameRoot))
        .patchHashes(sourceArchive: sourceArchive, targetArchive: targetArchive, hashes: [requestedHash])

    #expect(summary.patchedCount == 1)
    #expect(summary.replacedCount == 1)
    #expect(summary.insertedCount == 0)

    let patched = try RDARArchive.read(targetArchive)
    #expect(patched.records.filter { $0.nameHash == duplicateHash }.count == 2)
    #expect(patched.records.filter { $0.nameHash == requestedHash }.count == 1)
    #expect(patched.storedCRC == patched.computedCRC)
}

@Test func patchReplacesIdenticalDuplicateTargetHashes() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "cp2077-patcher-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let gameRoot = root.appending(path: "Game", directoryHint: .isDirectory)
    let contentDir = gameRoot.appending(path: "archive/Mac/content", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: contentDir, withIntermediateDirectories: true)

    let requestedHash: UInt64 = 0x3a22ea66fb2448f4
    let sourceArchive = root.appending(path: "source.archive")
    let targetArchive = contentDir.appending(path: "basegame_3_test.archive")

    try writeTestArchive(
        to: sourceArchive,
        records: [
            TestRecord(hash: requestedHash, payload: Data("replacement-night-sky".utf8))
        ]
    )
    try writeTestArchive(
        to: targetArchive,
        records: [
            TestRecord(hash: requestedHash, payload: Data("original-night-sky".utf8), sha1Fill: 1),
            TestRecord(hash: requestedHash, payload: Data("original-night-sky".utf8), sha1Fill: 2)
        ]
    )

    let summary = try RDARPatcher(game: GameInstall(root: gameRoot))
        .patchHashes(sourceArchive: sourceArchive, targetArchive: targetArchive, hashes: [requestedHash])

    #expect(summary.patchedCount == 1)
    #expect(summary.replacedCount == 1)
    #expect(summary.insertedCount == 0)

    let patched = try RDARArchive.read(targetArchive)
    let patchedRecords = patched.records.filter { $0.nameHash == requestedHash }
    #expect(patchedRecords.count == 2)
    #expect(patchedRecords.allSatisfy { record in
        (try? compressedRecordData(record, in: patched)) == Data("replacement-night-sky".utf8)
    })
    #expect(Set(patchedRecords.map(\.segmentsStart)).count == 1)
    #expect(Set(patchedRecords.map(\.segmentsEnd)).count == 1)
    #expect(patched.storedCRC == patched.computedCRC)
}

@Test func patchRejectsNonIdenticalDuplicateTargetHashes() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "cp2077-patcher-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let gameRoot = root.appending(path: "Game", directoryHint: .isDirectory)
    let contentDir = gameRoot.appending(path: "archive/Mac/content", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: contentDir, withIntermediateDirectories: true)

    let requestedHash: UInt64 = 0x3a22ea66fb2448f4
    let sourceArchive = root.appending(path: "source.archive")
    let targetArchive = contentDir.appending(path: "basegame_3_test.archive")

    try writeTestArchive(
        to: sourceArchive,
        records: [
            TestRecord(hash: requestedHash, payload: Data("replacement-night-sky".utf8))
        ]
    )
    try writeTestArchive(
        to: targetArchive,
        records: [
            TestRecord(hash: requestedHash, payload: Data("original-night-sky-a".utf8)),
            TestRecord(hash: requestedHash, payload: Data("original-night-sky-b".utf8))
        ]
    )

    #expect(throws: RDARArchiveError.self) {
        try RDARPatcher(game: GameInstall(root: gameRoot))
            .patchHashes(sourceArchive: sourceArchive, targetArchive: targetArchive, hashes: [requestedHash])
    }
}
