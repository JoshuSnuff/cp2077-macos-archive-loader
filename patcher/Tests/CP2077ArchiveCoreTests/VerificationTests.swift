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

@Test func verifyChecksTheConsolidatedArchiveAgainstNewResources() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let mod = try game.writeMod("mod.archive", records: [
        TestRecord(
            hash: 0x9999,
            payload: Data("new".utf8),
            timestamp: 9,
            inlineBufferSegments: 2,
            sha1Fill: 9,
            dependencies: [0xbeef]
        )
    ])
    let plan = try PatchPlanner.plan(mods: [mod], game: game.install)
    _ = try RDARPatcher(game: game.install).apply(plan: plan)

    let report = try PlanVerifier.verify(plan: plan, game: game.install)

    #expect(report.isClean)
    #expect(report.matchingRecordCount == 1)
    #expect(report.archives.contains { $0.archive == game.install.managedLooseArchive.normalizedFileURL })
}

@Test func verifyDetectsAMissingConsolidatedArchive() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let mod = try game.writeMod("mod.archive", records: [
        TestRecord(hash: 0x9999, payload: Data("new".utf8))
    ])
    let plan = try PatchPlanner.plan(mods: [mod], game: game.install)

    let report = try PlanVerifier.verify(plan: plan, game: game.install)

    #expect(!report.isClean)
    #expect(report.differingRecordCount == 1)
    #expect(report.archives.flatMap(\.issues).contains { $0.contains("absent") })
}

@Test func verifyDetectsDuplicateNewResourcesInTheConsolidatedArchive() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let modURL = try game.writeMod("duplicate.archive", records: [
        TestRecord(hash: 0x9999, payload: Data("first".utf8)),
        TestRecord(hash: 0x9999, payload: Data("second".utf8))
    ])
    let plan = try PatchPlanner.plan(mods: [modURL], game: game.install)
    try RDARWriter.write(archive: RDARArchive.read(modURL), to: game.install.managedLooseArchive)

    let report = try PlanVerifier.verify(plan: plan, game: game.install)

    #expect(!report.isClean)
    #expect(report.archives.flatMap(\.issues).contains { $0.contains("occurs 2 times") })
}

@Test func verifyRejectsAnOfficiallyOwnedRecordInTheConsolidatedArchive() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let officialHash: UInt64 = 0x1111
    try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: officialHash, payload: Data("stock".utf8))
    ])
    let mod = try game.writeMod("mod.archive", records: [
        TestRecord(hash: 0x9999, payload: Data("new".utf8))
    ])
    let plan = try PatchPlanner.plan(mods: [mod], game: game.install)
    _ = try RDARPatcher(game: game.install).apply(plan: plan)
    try rewriteIndex(of: game.install.managedLooseArchive) { index, archive in
        try index.writeUInt64LEForTest(officialHash, at: archive.recordsOffset)
    }

    let report = try PlanVerifier.verify(plan: plan, game: game.install)
    let issues = report.archives.flatMap(\.issues)

    #expect(!report.isClean)
    #expect(issues.contains { $0.contains("owned by an official archive") })
    #expect(issues.contains { $0.contains("not a planned new resource") })
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

// MARK: - Negative tests for the checks that had none
//
// Each plants exactly the corruption its check exists to catch. Without these
// the checks are reachable but never proven to fire.

/// Moves an archive's index off its 4096-byte boundary, keeping the file size
/// aligned and the header self-consistent so only the one check trips.
private func misalignIndexPosition(of url: URL) throws {
    let archive = try RDARArchive.read(url)
    let data = try Data(contentsOf: url)
    let start = Int(archive.indexPosition)
    let index = Data(data[start..<start + Int(archive.indexSize)])

    var out = Data(data[0..<start])
    out.append(Data(count: 8))
    out.append(index)
    let aligned = alignUpForTest(UInt64(out.count), to: 4096)
    out.append(Data(count: Int(aligned) - out.count))

    try out.writeUInt64LEForTest(archive.indexPosition + 8, at: 8)
    try out.writeUInt64LEForTest(aligned, at: 32)
    try out.write(to: url)
}

/// Grows the file by one byte and tells the header so, leaving the recorded
/// size honest but no longer 4096-aligned.
private func misalignFileSize(of url: URL) throws {
    let archive = try RDARArchive.read(url)
    var data = try Data(contentsOf: url)
    data.append(0)
    try data.writeUInt64LEForTest(archive.fileSize + 1, at: 32)
    try data.write(to: url)
}

@Test func verifyDetectsAnUnalignedIndexPosition() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let target = try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("stock".utf8))
    ])
    try misalignIndexPosition(of: target)

    let report = try PlanVerifier.verify(
        plan: PatchPlan(winners: [:], officialWork: [:], newResources: [], losers: []),
        game: game.install
    )

    #expect(!report.isClean)
    #expect(report.archives.flatMap { $0.issues }.contains { $0.contains("index position") })
}

@Test func verifyDetectsAnUnalignedFileSize() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let target = try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("stock".utf8))
    ])
    try misalignFileSize(of: target)

    let report = try PlanVerifier.verify(
        plan: PatchPlan(winners: [:], officialWork: [:], newResources: [], losers: []),
        game: game.install
    )

    #expect(!report.isClean)
    #expect(report.archives.flatMap { $0.issues }.contains { $0.contains("file size") })
}

@Test func verifyDetectsASegmentRangeOutsideTheSegmentTable() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let hash: UInt64 = 0x1111
    let target = try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: hash, payload: Data("stock".utf8))
    ])
    let mod = try game.writeMod("mod.archive", records: [
        TestRecord(hash: hash, payload: Data("mod".utf8))
    ])
    let plan = try PatchPlanner.plan(mods: [mod], game: game.install)
    _ = try RDARPatcher(game: game.install).apply(plan: plan)

    let patched = try RDARArchive.read(target)
    let offset = patched.records.first { $0.nameHash == hash }!.offset
    try rewriteIndex(of: target) { index, archive in
        try index.writeUInt32LEForTest(archive.fileSegmentCount + 9, at: offset + 24)
    }

    let report = try PlanVerifier.verify(plan: plan, game: game.install)

    #expect(!report.isClean)
    let recordIssues = report.archives.flatMap { $0.records }.flatMap { $0.issues }
    #expect(recordIssues.contains { $0.contains("segment range") })
}

@Test func verifyDetectsADependencyRangeOutsideDependencyCount() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let hash: UInt64 = 0x1111
    let target = try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: hash, payload: Data("stock".utf8), dependencies: [0xdead])
    ])
    let mod = try game.writeMod("mod.archive", records: [
        TestRecord(hash: hash, payload: Data("mod".utf8), dependencies: [0xbeef])
    ])
    let plan = try PatchPlanner.plan(mods: [mod], game: game.install)
    _ = try RDARPatcher(game: game.install).apply(plan: plan)

    let patched = try RDARArchive.read(target)
    let offset = patched.records.first { $0.nameHash == hash }!.offset
    try rewriteIndex(of: target) { index, archive in
        try index.writeUInt32LEForTest(archive.dependencyCount + 9, at: offset + 32)
    }

    let report = try PlanVerifier.verify(plan: plan, game: game.install)

    #expect(!report.isClean)
    let recordIssues = report.archives.flatMap { $0.records }.flatMap { $0.issues }
    #expect(recordIssues.contains { $0.contains("dependency range") })
}

@Test func verifyDetectsASegmentCountThatDiffersFromThePlan() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let hash: UInt64 = 0x1111
    // Everything the verifier compares matches except the segment count, so
    // this isolates that one check.
    try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: hash, payload: Data("stock".utf8), timestamp: 5, inlineBufferSegments: 3, sha1Fill: 7)
    ])
    let mod = try game.writeMod("mod.archive", records: [
        TestRecord(
            hash: hash,
            payloads: [Data("mod-a".utf8), Data("mod-b".utf8)],
            timestamp: 5,
            inlineBufferSegments: 3,
            sha1Fill: 7
        )
    ])

    let plan = try PatchPlanner.plan(mods: [mod], game: game.install)
    let report = try PlanVerifier.verify(plan: plan, game: game.install)

    #expect(!report.isClean)
    #expect(report.differingRecordCount == 1)
    let recordIssues = report.archives.flatMap { $0.records }.flatMap { $0.issues }
    #expect(recordIssues.contains { $0.contains("segment count") })
}

@Test func verifyDetectsASha1MismatchOnItsOwn() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let hash: UInt64 = 0x1111
    // Identical in every compared field but the SHA-1, so a verdict here can
    // only come from the sha1 check.
    try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: hash, payload: Data("same".utf8), timestamp: 5, inlineBufferSegments: 3, sha1Fill: 1)
    ])
    let mod = try game.writeMod("mod.archive", records: [
        TestRecord(hash: hash, payload: Data("same".utf8), timestamp: 5, inlineBufferSegments: 3, sha1Fill: 2)
    ])

    let plan = try PatchPlanner.plan(mods: [mod], game: game.install)
    let report = try PlanVerifier.verify(plan: plan, game: game.install)

    #expect(!report.isClean)
    #expect(report.differingRecordCount == 1)
    let recordIssues = report.archives.flatMap { $0.records }.flatMap { $0.issues }
    #expect(recordIssues.contains { $0.contains("sha1") })
    #expect(!recordIssues.contains { $0.contains("timestamp") })
}
