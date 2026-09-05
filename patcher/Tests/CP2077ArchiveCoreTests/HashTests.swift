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

private struct TestRecord {
    let hash: UInt64
    let payload: Data
    var sha1Fill: UInt8 = 0
}

private enum TestArchiveError: Error {
    case shortRead(URL, Int)
}

private func writeTestArchive(to url: URL, records: [TestRecord]) throws {
    var body = Data(count: 52)
    var recordEntries: [(record: TestRecord, offset: UInt64)] = []
    for record in records {
        let offset = UInt64(body.count)
        body.append(record.payload)
        recordEntries.append((record, offset))
    }

    let indexPosition = alignUpForTest(UInt64(body.count), to: 4096)
    body.append(Data(count: Int(indexPosition) - body.count))

    var index = Data(count: 28 + records.count * 56 + records.count * 16)
    try index.writeUInt32LEForTest(UInt32(index.count), at: 4)
    try index.writeUInt32LEForTest(UInt32(records.count), at: 16)
    try index.writeUInt32LEForTest(UInt32(records.count), at: 20)
    try index.writeUInt32LEForTest(0, at: 24)

    let recordsOffset = 28
    let segmentsOffset = recordsOffset + records.count * 56
    for (i, entry) in recordEntries.enumerated() {
        let recordOffset = recordsOffset + i * 56
        try index.writeUInt64LEForTest(entry.record.hash, at: recordOffset)
        try index.writeUInt32LEForTest(UInt32(i), at: recordOffset + 20)
        try index.writeUInt32LEForTest(UInt32(i + 1), at: recordOffset + 24)
        try index.writeUInt32LEForTest(0, at: recordOffset + 28)
        try index.writeUInt32LEForTest(0, at: recordOffset + 32)
        index.replaceSubrange(recordOffset + 36..<recordOffset + 56, with: Data(repeating: entry.record.sha1Fill, count: 20))

        let segmentOffset = segmentsOffset + i * 16
        try index.writeUInt64LEForTest(entry.offset, at: segmentOffset)
        try index.writeUInt32LEForTest(UInt32(entry.record.payload.count), at: segmentOffset + 8)
        try index.writeUInt32LEForTest(UInt32(entry.record.payload.count), at: segmentOffset + 12)
    }
    try index.writeUInt64LEForTest(Hashes.crc64(index.subdata(in: 16..<index.count)), at: 8)

    body.append(index)
    let fileSize = alignUpForTest(UInt64(body.count), to: 4096)
    body.append(Data(count: Int(fileSize) - body.count))

    body.replaceSubrange(0..<4, with: Data("RDAR".utf8))
    try body.writeUInt64LEForTest(indexPosition, at: 8)
    try body.writeUInt32LEForTest(UInt32(index.count), at: 16)
    try body.writeUInt64LEForTest(fileSize, at: 32)

    try body.write(to: url)
}

private func compressedRecordData(_ record: RDARRecord, in archive: RDARArchive) throws -> Data {
    let handle = try FileHandle(forReadingFrom: archive.url)
    defer { try? handle.close() }

    var data = Data()
    for i in 0..<record.segmentCount {
        let segment = archive.segments[Int(record.segmentsStart) + i]
        try handle.seek(toOffset: segment.offset)
        let chunk = try handle.read(upToCount: Int(segment.compressedSize)) ?? Data()
        guard chunk.count == Int(segment.compressedSize) else {
            throw TestArchiveError.shortRead(archive.url, Int(segment.compressedSize))
        }
        data.append(chunk)
    }
    return data
}

private func alignUpForTest(_ value: UInt64, to alignment: UInt64) -> UInt64 {
    ((value + alignment - 1) / alignment) * alignment
}

private extension Data {
    mutating func writeUInt32LEForTest(_ value: UInt32, at offset: Int) throws {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { bytes in
            replaceSubrange(offset..<offset + 4, with: bytes)
        }
    }

    mutating func writeUInt64LEForTest(_ value: UInt64, at offset: Int) throws {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { bytes in
            replaceSubrange(offset..<offset + 8, with: bytes)
        }
    }
}
