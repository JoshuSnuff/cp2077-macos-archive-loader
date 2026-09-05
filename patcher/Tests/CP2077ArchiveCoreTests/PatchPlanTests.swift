import CP2077ArchiveCore
import Foundation
import Testing

@Test func planPicksTheFirstModInAsciiOrderAsWinner() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let contested: UInt64 = 0x1111
    try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: contested, payload: Data("stock".utf8))
    ])
    let first = try game.writeMod("a_first.archive", records: [
        TestRecord(hash: contested, payload: Data("first".utf8), sha1Fill: 1)
    ])
    let second = try game.writeMod("z_second.archive", records: [
        TestRecord(hash: contested, payload: Data("second".utf8), sha1Fill: 2)
    ])

    // Deliberately passed out of order: the planner sorts, matching `sort -z`.
    let plan = try PatchPlanner.plan(mods: [second, first], game: game.install)

    #expect(plan.winners[contested]?.modArchive == first)
    #expect(plan.losers.count == 1)
    #expect(plan.losers.first?.modArchive == second)
    #expect(plan.losers.first?.hash == contested)
}

@Test func planCreatesWorkForEveryOfficialOwnerOfAHash() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let shared: UInt64 = 0x2222
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

    #expect(plan.officialWork[a] == [shared])
    #expect(plan.officialWork[b] == [shared])
    #expect(plan.newResources.isEmpty)
}

@Test func planPartitionsNewResourcesFromOverrides() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let override: UInt64 = 0x3333
    let brandNew: UInt64 = 0x4444
    try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: override, payload: Data("stock".utf8))
    ])
    let mod = try game.writeMod("mod.archive", records: [
        TestRecord(hash: override, payload: Data("mod".utf8)),
        TestRecord(hash: brandNew, payload: Data("new".utf8))
    ])

    let plan = try PatchPlanner.plan(mods: [mod], game: game.install)

    #expect(plan.newResources == [brandNew])
    #expect(plan.officialWork.values.flatMap { $0 } == [override])
}

@Test func planCarriesTheWinningModsDependencies() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let hash: UInt64 = 0x5555
    try game.writeOfficial("basegame_1_stock.archive", records: [
        TestRecord(hash: hash, payload: Data("stock".utf8), dependencies: [0xdead])
    ])
    let mod = try game.writeMod("mod.archive", records: [
        TestRecord(hash: hash, payload: Data("mod".utf8), dependencies: [0xbeef, 0xcafe])
    ])

    let plan = try PatchPlanner.plan(mods: [mod], game: game.install)

    #expect(plan.winners[hash]?.dependencies == [0xbeef, 0xcafe])
}

@Test func planIgnoresLooseArchivesWhenResolvingOwners() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let hash: UInt64 = 0x6666
    // A loose archive left over from an earlier run must not count as an owner.
    try game.writeOfficial("basegame_99_leftover.archive", records: [
        TestRecord(hash: hash, payload: Data("leftover".utf8))
    ])
    let mod = try game.writeMod("mod.archive", records: [
        TestRecord(hash: hash, payload: Data("mod".utf8))
    ])

    let plan = try PatchPlanner.plan(mods: [mod], game: game.install)

    #expect(plan.officialWork.isEmpty)
    #expect(plan.newResources == [hash])
}
