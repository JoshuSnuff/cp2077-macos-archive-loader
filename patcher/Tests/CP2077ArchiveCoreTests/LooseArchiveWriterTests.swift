import CP2077ArchiveCore
import Foundation
import Testing

@Test func writerRoundTripsAnExistingArchiveSemantically() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let sourceURL = try game.writeMod("source.archive", records: [
        TestRecord(
            hash: 0x2222,
            payloads: [Data("two-a".utf8), Data("two-b".utf8)],
            timestamp: 22,
            inlineBufferSegments: 2,
            sha1Fill: 0x22,
            dependencies: [0xaaaa, 0xbbbb]
        ),
        TestRecord(
            hash: 0x1111,
            payload: Data("one".utf8),
            timestamp: 11,
            inlineBufferSegments: 1,
            sha1Fill: 0x11,
            dependencies: [0xcccc]
        )
    ])
    let sourceHandle = try FileHandle(forUpdating: sourceURL)
    try sourceHandle.seek(toOffset: 4)
    try sourceHandle.write(contentsOf: Data([0x7a]))
    try sourceHandle.close()

    let source = try RDARArchive.read(sourceURL)
    let outputURL = game.root.appending(path: "round-trip.archive")
    try RDARWriter.write(archive: source, to: outputURL)
    let output = try RDARArchive.read(outputURL)

    #expect(output.records.map(\.nameHash) == [0x1111, 0x2222])
    #expect(output.header[4] == 0x7a)
    #expect(output.storedCRC == output.computedCRC)
    #expect(output.indexPosition % 4096 == 0)
    #expect(output.fileSize % 4096 == 0)

    for sourceRecord in source.records {
        let emitted = output.record(hash: sourceRecord.nameHash)!
        #expect(emitted.timestamp == sourceRecord.timestamp)
        #expect(emitted.numInlineBufferSegments == sourceRecord.numInlineBufferSegments)
        #expect(emitted.sha1 == sourceRecord.sha1)
        #expect(emitted.segmentCount == sourceRecord.segmentCount)
        let sourceSegments = Array(
            source.segments[Int(sourceRecord.segmentsStart)..<Int(sourceRecord.segmentsEnd)]
        )
        let emittedSegments = Array(
            output.segments[Int(emitted.segmentsStart)..<Int(emitted.segmentsEnd)]
        )
        #expect(emittedSegments.map(\.compressedSize) == sourceSegments.map(\.compressedSize))
        #expect(emittedSegments.map(\.size) == sourceSegments.map(\.size))
        #expect(try output.dependencies(for: emitted) == source.dependencies(for: sourceRecord))
        #expect(try compressedRecordData(emitted, in: output) == compressedRecordData(sourceRecord, in: source))
    }
}

@Test func entirelyNewSingleModProducesAnEquivalentRecordSet() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let modURL = try game.writeMod("all-new.archive", records: [
        TestRecord(hash: 0x2222, payload: Data("two".utf8), timestamp: 2, sha1Fill: 2),
        TestRecord(hash: 0x1111, payload: Data("one".utf8), timestamp: 1, sha1Fill: 1)
    ])
    let source = try RDARArchive.read(modURL)
    let plan = try PatchPlanner.plan(mods: [modURL], game: game.install)
    let summary = try RDARPatcher(game: game.install).apply(plan: plan)
    let loose = try RDARArchive.read(summary.looseArchive!)

    #expect(loose.records.map(\.nameHash) == [0x1111, 0x2222])
    #expect(Set(loose.records.map(\.nameHash)) == Set(source.records.map(\.nameHash)))
    for record in source.records {
        #expect(
            try compressedRecordData(loose.record(hash: record.nameHash)!, in: loose)
                == compressedRecordData(record, in: source)
        )
    }
}

@Test func multipleModsProduceOneSortedUnionAndUseTheLargestContributorAsTemplate() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let first = try game.writeMod("a_first.archive", records: [
        TestRecord(hash: 0x3333, payload: Data("three".utf8)),
        TestRecord(hash: 0x1111, payload: Data("one".utf8))
    ])
    let second = try game.writeMod("z_second.archive", records: [
        TestRecord(hash: 0x2222, payload: Data("two".utf8))
    ])
    try setHeaderMarker(0xa1, in: first)
    try setHeaderMarker(0xb2, in: second)

    let plan = try PatchPlanner.plan(mods: [second, first], game: game.install)
    let patcher = RDARPatcher(game: game.install)
    let summary = try patcher.apply(plan: plan)
    let firstEmission = try Data(contentsOf: summary.looseArchive!)
    // The fixed path is replaced deterministically if a caller repeats a run
    // without the shell restoration step.
    _ = try patcher.apply(plan: plan)
    #expect(try Data(contentsOf: summary.looseArchive!) == firstEmission)
    let loose = try RDARArchive.read(summary.looseArchive!)
    let managed = try game.install.macArchives().filter { $0.lastPathComponent.hasPrefix("basegame_99_") }

    #expect(managed == [game.install.managedLooseArchive.normalizedFileURL])
    #expect(loose.records.map(\.nameHash) == [0x1111, 0x2222, 0x3333])
    #expect(loose.header[4] == 0xa1)
}

@Test func newResourceConflictUsesTheFirstModAndWritesOneCopy() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let first = try game.writeMod("a_first.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("winner".utf8), sha1Fill: 1)
    ])
    let second = try game.writeMod("z_second.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("loser".utf8), sha1Fill: 2)
    ])

    let plan = try PatchPlanner.plan(mods: [second, first], game: game.install)
    let summary = try RDARPatcher(game: game.install).apply(plan: plan)
    let loose = try RDARArchive.read(summary.looseArchive!)

    #expect(plan.losers.count == 1)
    #expect(loose.records.filter { $0.nameHash == 0x1111 }.count == 1)
    #expect(try compressedRecordData(loose.records[0], in: loose) == Data("winner".utf8))
}

@Test func consolidatedArchiveCarriesDependenciesInOrder() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let mod = try game.writeMod("dependencies.archive", records: [
        TestRecord(
            hash: 0x1111,
            payload: Data("new".utf8),
            dependencies: [0xdead, 0xbeef, 0xcafe]
        )
    ])

    let plan = try PatchPlanner.plan(mods: [mod], game: game.install)
    let summary = try RDARPatcher(game: game.install).apply(plan: plan)
    let loose = try RDARArchive.read(summary.looseArchive!)

    #expect(loose.dependencyCount == 3)
    #expect(try loose.dependencies(for: loose.records[0]) == [0xdead, 0xbeef, 0xcafe])
}

private func setHeaderMarker(_ marker: UInt8, in archive: URL) throws {
    let handle = try FileHandle(forUpdating: archive)
    try handle.seek(toOffset: 4)
    try handle.write(contentsOf: Data([marker]))
    try handle.close()
}
