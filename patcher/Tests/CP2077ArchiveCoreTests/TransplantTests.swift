import CP2077ArchiveCore
import Foundation
import Testing

@Test func transplantCarriesEverySourceOwnedField() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let hash: UInt64 = 0x1111
    let target = try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(
            hash: hash,
            payload: Data("stock".utf8),
            timestamp: 0x1111_1111_1111_1111,
            inlineBufferSegments: 1,
            sha1Fill: 0x11
        )
    ])
    let mod = try game.writeMod("mod.archive", records: [
        TestRecord(
            hash: hash,
            payload: Data("mod-payload".utf8),
            timestamp: 0x2222_2222_2222_2222,
            inlineBufferSegments: 7,
            sha1Fill: 0x22
        )
    ])

    let plan = try PatchPlanner.plan(mods: [mod], game: game.install)
    _ = try RDARPatcher(game: game.install).apply(plan: plan)

    let patched = try RDARArchive.read(target)
    let record = patched.record(hash: hash)!
    #expect(record.timestamp == 0x2222_2222_2222_2222)
    #expect(record.numInlineBufferSegments == 7)
    #expect(record.sha1 == Data(repeating: 0x22, count: 20))
    #expect(try compressedRecordData(record, in: patched) == Data("mod-payload".utf8))
    #expect(patched.storedCRC == patched.computedCRC)
}

@Test func transplantCarriesTheModsDependenciesInsteadOfTheStockRecords() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let hash: UInt64 = 0x2222
    let target = try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: hash, payload: Data("stock".utf8), dependencies: [0xdead])
    ])
    let mod = try game.writeMod("mod.archive", records: [
        TestRecord(hash: hash, payload: Data("mod".utf8), dependencies: [0xbeef, 0xcafe])
    ])

    let plan = try PatchPlanner.plan(mods: [mod], game: game.install)
    _ = try RDARPatcher(game: game.install).apply(plan: plan)

    let patched = try RDARArchive.read(target)
    #expect(try patched.dependencies(for: patched.record(hash: hash)!) == [0xbeef, 0xcafe])
}

@Test func transplantDropsStockDependenciesWhenTheModDeclaresNone() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let hash: UInt64 = 0x2233
    let target = try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: hash, payload: Data("stock".utf8), dependencies: [0xdead, 0xd00d])
    ])
    let mod = try game.writeMod("mod.archive", records: [
        TestRecord(hash: hash, payload: Data("mod".utf8), dependencies: [])
    ])

    let plan = try PatchPlanner.plan(mods: [mod], game: game.install)
    _ = try RDARPatcher(game: game.install).apply(plan: plan)

    let patched = try RDARArchive.read(target)
    #expect(try patched.dependencies(for: patched.record(hash: hash)!) == [])
}

@Test func appendingDependenciesLeavesExistingRangesIntact() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let untouched: UInt64 = 0x1111
    let patchedHash: UInt64 = 0x2222
    let target = try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: untouched, payload: Data("keep".utf8), dependencies: [0xdead]),
        TestRecord(hash: patchedHash, payload: Data("stock".utf8), dependencies: [0xf00d])
    ])
    let mod = try game.writeMod("mod.archive", records: [
        TestRecord(hash: patchedHash, payload: Data("mod".utf8), dependencies: [0xbeef, 0xcafe])
    ])

    let plan = try PatchPlanner.plan(mods: [mod], game: game.install)
    _ = try RDARPatcher(game: game.install).apply(plan: plan)

    let patched = try RDARArchive.read(target)
    #expect(try patched.dependencies(for: patched.record(hash: untouched)!) == [0xdead])
    #expect(patched.dependencies == [0xdead, 0xf00d, 0xbeef, 0xcafe])
}

@Test func patchUpdatesTheDependencyCountHeader() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let hash: UInt64 = 0x2222
    let target = try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: hash, payload: Data("stock".utf8), dependencies: [0xdead])
    ])
    let mod = try game.writeMod("mod.archive", records: [
        TestRecord(hash: hash, payload: Data("mod".utf8), dependencies: [0xbeef, 0xcafe])
    ])

    let plan = try PatchPlanner.plan(mods: [mod], game: game.install)
    _ = try RDARPatcher(game: game.install).apply(plan: plan)

    let patched = try RDARArchive.read(target)
    // Header count must agree with the actual table, or the index is valid-looking and wrong.
    #expect(patched.dependencyCount == 3)
    #expect(patched.dependenciesOffset + Int(patched.dependencyCount) * 8 == patched.indexData.count)
    #expect(patched.storedCRC == patched.computedCRC)
}

@Test func patchInsertsNewRecordsThatCarryDependencies() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let stock: UInt64 = 0x1111
    let inserted: UInt64 = 0x9999
    let target = try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: stock, payload: Data("stock".utf8))
    ])
    let mod = try game.writeMod("mod.archive", records: [
        TestRecord(hash: stock, payload: Data("mod".utf8)),
        TestRecord(hash: inserted, payload: Data("new".utf8), dependencies: [0xbeef])
    ])

    // The inserted record is a new resource, so it also ships loose; the point
    // here is that a dependency-bearing record is no longer rejected outright.
    let plan = try PatchPlanner.plan(mods: [mod], game: game.install)
    _ = try RDARPatcher(game: game.install).apply(
        plan: PatchPlan(
            winners: plan.winners,
            officialWork: [target: [stock, inserted]],
            newResources: [],
            losers: []
        )
    )

    let patched = try RDARArchive.read(target)
    #expect(try patched.dependencies(for: patched.record(hash: inserted)!) == [0xbeef])
    #expect(try compressedRecordData(patched.record(hash: inserted)!, in: patched) == Data("new".utf8))
    #expect(patched.storedCRC == patched.computedCRC)
}

@Test func patchBacksUpEachTargetArchiveOnlyOncePerRun() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let target = try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("stock-a".utf8)),
        TestRecord(hash: 0x2222, payload: Data("stock-b".utf8))
    ])
    let first = try game.writeMod("a_first.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("first".utf8))
    ])
    let second = try game.writeMod("b_second.archive", records: [
        TestRecord(hash: 0x2222, payload: Data("second".utf8))
    ])

    let plan = try PatchPlanner.plan(mods: [first, second], game: game.install)
    let summary = try RDARPatcher(game: game.install).apply(plan: plan)

    #expect(summary.archives.count == 1)
    let backups = try FileManager.default.contentsOfDirectory(
        at: game.install.backupDirectory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    )
    #expect(backups.count == 1)

    // Both mods' payloads land, in one rewrite of the target.
    let patched = try RDARArchive.read(target)
    #expect(try compressedRecordData(patched.record(hash: 0x1111)!, in: patched) == Data("first".utf8))
    #expect(try compressedRecordData(patched.record(hash: 0x2222)!, in: patched) == Data("second".utf8))
    #expect(patched.storedCRC == patched.computedCRC)
}

@Test func patchAppliesTheWinnerToEveryOfficialOwner() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let shared: UInt64 = 0x3333
    let a = try game.writeOfficial("basegame_1_a.archive", records: [
        TestRecord(hash: shared, payload: Data("stock-a".utf8))
    ])
    let b = try game.writeOfficial("basegame_2_b.archive", records: [
        TestRecord(hash: shared, payload: Data("stock-b".utf8))
    ])
    let mod = try game.writeMod("mod.archive", records: [
        TestRecord(hash: shared, payload: Data("mod".utf8))
    ])

    let plan = try PatchPlanner.plan(mods: [mod], game: game.install)
    _ = try RDARPatcher(game: game.install).apply(plan: plan)

    for url in [a, b] {
        let patched = try RDARArchive.read(url)
        #expect(try compressedRecordData(patched.record(hash: shared)!, in: patched) == Data("mod".utf8))
    }
}

@Test func patchReplacesEveryIdenticalDuplicateOfATargetHash() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let hash: UInt64 = 0x4444
    let target = try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: hash, payload: Data("stock".utf8), sha1Fill: 1),
        TestRecord(hash: hash, payload: Data("stock".utf8), sha1Fill: 2)
    ])
    let mod = try game.writeMod("mod.archive", records: [
        TestRecord(hash: hash, payload: Data("mod".utf8), timestamp: 0x77, sha1Fill: 0x33)
    ])

    let plan = try PatchPlanner.plan(mods: [mod], game: game.install)
    _ = try RDARPatcher(game: game.install).apply(plan: plan)

    let patched = try RDARArchive.read(target)
    let records = patched.records.filter { $0.nameHash == hash }
    #expect(records.count == 2)
    #expect(records.allSatisfy { $0.timestamp == 0x77 })
    #expect(records.allSatisfy { $0.sha1 == Data(repeating: 0x33, count: 20) })
    #expect(patched.storedCRC == patched.computedCRC)
}

@Test func patchShipsNewResourcesInTheConsolidatedLooseArchive() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("stock".utf8))
    ])
    let mod = try game.writeMod("mod.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("mod".utf8)),
        TestRecord(hash: 0x9999, payload: Data("new".utf8))
    ])

    let plan = try PatchPlanner.plan(mods: [mod], game: game.install)
    let summary = try RDARPatcher(game: game.install).apply(plan: plan)

    #expect(summary.looseArchive?.lastPathComponent == "basegame_99_cp2077_runtime.archive")
    #expect(FileManager.default.fileExists(atPath: summary.looseArchive!.path))

    let loose = try RDARArchive.read(summary.looseArchive!)
    #expect(loose.records.map(\.nameHash) == [0x9999])
    #expect(try compressedRecordData(loose.records[0], in: loose) == Data("new".utf8))
}
