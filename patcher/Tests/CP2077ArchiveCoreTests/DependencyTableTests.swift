import CP2077ArchiveCore
import Foundation
import Testing

@Test func archiveParsesDependencyTableAsHashes() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let url = try game.writeMod("deps.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("a".utf8), dependencies: [0xaaaa, 0xbbbb]),
        TestRecord(hash: 0x2222, payload: Data("b".utf8), dependencies: []),
        TestRecord(hash: 0x3333, payload: Data("c".utf8), dependencies: [0xcccc])
    ])

    let archive = try RDARArchive.read(url)

    #expect(archive.dependencyCount == 3)
    #expect(archive.dependencies == [0xaaaa, 0xbbbb, 0xcccc])
}

@Test func archiveResolvesEachRecordsDependencySlice() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let url = try game.writeMod("deps.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("a".utf8), dependencies: [0xaaaa, 0xbbbb]),
        TestRecord(hash: 0x2222, payload: Data("b".utf8), dependencies: []),
        TestRecord(hash: 0x3333, payload: Data("c".utf8), dependencies: [0xcccc])
    ])

    let archive = try RDARArchive.read(url)

    #expect(try archive.dependencies(for: archive.record(hash: 0x1111)!) == [0xaaaa, 0xbbbb])
    #expect(try archive.dependencies(for: archive.record(hash: 0x2222)!) == [])
    #expect(try archive.dependencies(for: archive.record(hash: 0x3333)!) == [0xcccc])
}

@Test func dependencyTableIsLastInTheIndex() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let url = try game.writeMod("deps.archive", records: [
        TestRecord(hash: 0x1111, payload: Data("a".utf8), dependencies: [0xaaaa, 0xbbbb]),
        TestRecord(hash: 0x3333, payload: Data("c".utf8), dependencies: [0xcccc])
    ])

    let archive = try RDARArchive.read(url)

    #expect(archive.dependenciesOffset + Int(archive.dependencyCount) * 8 == archive.indexData.count)
    #expect(archive.records.map(\.dependenciesEnd).max() == archive.dependencyCount)
}
