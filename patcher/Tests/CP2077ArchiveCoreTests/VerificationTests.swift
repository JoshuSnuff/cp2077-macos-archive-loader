import CP2077ArchiveCore
import Foundation
import Testing

@Test func verifyReportsEveryPlannedRecordAsMatchingAfterPatching() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("stock".utf8), timestamp: 1, dependencies: [0xdead])
    ])
    let mod = try game.writeMod("mod.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("mod".utf8), timestamp: 2, inlineBufferSegments: 4, sha1Fill: 9, dependencies: [0xbeef])
    ])

    let plan = try PatchPlanner.plan(mods: [mod], game: game.install)
    _ = try RDARPatcher(game: game.install).apply(plan: plan)

    let report = try PlanVerifier.verify(plan: plan, game: game.install)

    #expect(report.isClean)
    #expect(report.matchingRecordCount == 1)
    #expect(report.differingRecordCount == 0)
    #expect(report.unpatchedRecordCount == 0)
}

@Test func verifyReportsAnUnpatchedStockRecordWhenThePatchNeverRan() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("stock".utf8), timestamp: 1, inlineBufferSegments: 1, sha1Fill: 1)
    ])
    let mod = try game.writeMod("mod.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("mod".utf8), timestamp: 2, inlineBufferSegments: 2, sha1Fill: 2)
    ])

    let plan = try PatchPlanner.plan(mods: [mod], game: game.install)
    let report = try PlanVerifier.verify(plan: plan, game: game.install)

    #expect(!report.isClean)
    #expect(report.unpatchedRecordCount == 1)
    #expect(report.matchingRecordCount == 0)
}

@Test func verifyDetectsAStaleTimestampCarriedFromTheStockRecord() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    // The exact shape of the old defect: the mod's payload and SHA-1 landed,
    // but the record still carries the stock timestamp and buffer count.
    try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("mod".utf8), timestamp: 1, inlineBufferSegments: 1, sha1Fill: 9)
    ])
    let mod = try game.writeMod("mod.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("mod".utf8), timestamp: 2, inlineBufferSegments: 5, sha1Fill: 9)
    ])

    let plan = try PatchPlanner.plan(mods: [mod], game: game.install)
    let report = try PlanVerifier.verify(plan: plan, game: game.install)

    #expect(!report.isClean)
    #expect(report.differingRecordCount == 1)
    let issues = report.archives.flatMap { $0.records }.flatMap { $0.issues }
    #expect(issues.contains { $0.contains("timestamp") })
    #expect(issues.contains { $0.contains("inline") })
}

@Test func verifyDetectsDependenciesThatDoNotMatchThePlan() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("mod".utf8), timestamp: 2, inlineBufferSegments: 5, sha1Fill: 9, dependencies: [0xdead])
    ])
    let mod = try game.writeMod("mod.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("mod".utf8), timestamp: 2, inlineBufferSegments: 5, sha1Fill: 9, dependencies: [0xbeef])
    ])

    let plan = try PatchPlanner.plan(mods: [mod], game: game.install)
    let report = try PlanVerifier.verify(plan: plan, game: game.install)

    #expect(!report.isClean)
    let issues = report.archives.flatMap { $0.records }.flatMap { $0.issues }
    #expect(issues.contains { $0.contains("dependencies") })
}

@Test func verifyDetectsAHeaderCountThatDisagreesWithTheTable() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let target = try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("stock".utf8), dependencies: [0xdead])
    ])
    let mod = try game.writeMod("mod.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("mod".utf8), dependencies: [0xbeef])
    ])

    let plan = try PatchPlanner.plan(mods: [mod], game: game.install)
    _ = try RDARPatcher(game: game.install).apply(plan: plan)

    // Exactly the failure a missing dependencyCount write would produce: a
    // valid CRC over a header that undercounts the table.
    try rewriteIndex(of: target) { index, archive in
        try index.writeUInt32LEForTest(archive.dependencyCount - 1, at: 24)
    }

    let report = try PlanVerifier.verify(plan: plan, game: game.install)

    #expect(!report.isClean)
    #expect(report.archives.flatMap { $0.issues }.contains { $0.contains("dependencyCount") })
}

@Test func verifyDetectsASegmentPointingPastTheEndOfTheFile() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let target = try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("stock".utf8))
    ])
    let mod = try game.writeMod("mod.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("mod".utf8))
    ])

    let plan = try PatchPlanner.plan(mods: [mod], game: game.install)
    _ = try RDARPatcher(game: game.install).apply(plan: plan)

    let patchedRecord = try RDARArchive.read(target).record(hash: 0x1111)!
    try rewriteIndex(of: target) { index, archive in
        let offset = archive.segmentsOffset + Int(patchedRecord.segmentsStart) * 16
        try index.writeUInt64LEForTest(archive.fileSize + 4096, at: offset)
    }

    let report = try PlanVerifier.verify(plan: plan, game: game.install)

    #expect(!report.isClean)
    let issues = report.archives.flatMap { $0.records }.flatMap { $0.issues }
    #expect(issues.contains { $0.contains("segment") })
}

@Test func verifyDetectsAPlannedRecordMissingFromAnOwningArchive() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let a = try game.writeOfficial("basegame_1_a.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("stock-a".utf8), timestamp: 1, inlineBufferSegments: 1, sha1Fill: 1)
    ])
    let b = try game.writeOfficial("basegame_2_b.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("stock-b".utf8), timestamp: 1, inlineBufferSegments: 1, sha1Fill: 1)
    ])
    let mod = try game.writeMod("mod.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("mod".utf8), timestamp: 2, inlineBufferSegments: 2, sha1Fill: 2)
    ])

    let plan = try PatchPlanner.plan(mods: [mod], game: game.install)
    // Only one owner patched: the run crashed, or an older patcher stopped at
    // the lexicographically first owner.
    _ = try RDARPatcher(game: game.install).apply(
        plan: PatchPlan(
            winners: plan.winners,
            officialWork: [a: [0x1111]],
            newResources: [],
            losers: []
        )
    )

    let report = try PlanVerifier.verify(plan: plan, game: game.install)

    #expect(!report.isClean)
    #expect(report.archives.first { $0.archive == b }?.records.first?.verdict == .unpatchedStockRecord)
    #expect(report.archives.first { $0.archive == a }?.records.first?.verdict == .matchesPlan)
}

@Test func verifyStillCatchesStructuralDamage() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let target = try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("stock".utf8))
    ])

    let handle = try FileHandle(forUpdating: target)
    try handle.seek(toOffset: 0)
    // Corrupt the stored index CRC without recomputing it.
    let archive = try RDARArchive.read(target)
    try handle.seek(toOffset: archive.indexPosition + 8)
    try handle.write(contentsOf: Data(repeating: 0xff, count: 8))
    try handle.close()

    let report = try PlanVerifier.verify(
        plan: PatchPlan(winners: [:], officialWork: [:], newResources: [], losers: []),
        game: game.install
    )

    #expect(!report.isClean)
    #expect(report.archives.flatMap { $0.issues }.contains { $0.lowercased().contains("crc") })
}
