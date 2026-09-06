import CP2077ArchiveCore
import Foundation
import Testing

@Test func patchRejectsASourceRecordWhoseSegmentRangeIsOutOfBounds() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let hash: UInt64 = 0x1111
    let target = try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: hash, payload: Data("stock".utf8))
    ])
    let mod = try game.writeMod("mod.archive", records: [
        TestRecord(hash: hash, payload: Data("mod".utf8))
    ])

    // A mod record claiming more segments than its own table holds. Reading it
    // used to index straight past the end of the array and trap, and the trap
    // landed mid-rewrite of an official archive: payload bytes appended, header
    // and index not yet updated.
    try rewriteIndex(of: mod) { index, archive in
        let offset = archive.recordsOffset + 24
        try index.writeUInt32LEForTest(archive.fileSegmentCount + 5, at: offset)
    }

    let sizeBefore = try FileManager.default.attributesOfItem(atPath: target.path)[.size] as! NSNumber

    let plan = try PatchPlanner.plan(mods: [mod], game: game.install)
    #expect(throws: (any Error).self) {
        try RDARPatcher(game: game.install).apply(plan: plan)
    }

    // Rejected before the target was touched.
    let sizeAfter = try FileManager.default.attributesOfItem(atPath: target.path)[.size] as! NSNumber
    #expect(sizeAfter == sizeBefore)
    let reread = try RDARArchive.read(target)
    #expect(reread.storedCRC == reread.computedCRC)
    #expect(try compressedRecordData(reread.record(hash: hash)!, in: reread) == Data("stock".utf8))
}
