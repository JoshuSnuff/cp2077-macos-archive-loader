import CP2077ArchiveCore
import Foundation
import Testing

@Test func recordExposesTimestampAndInlineBufferCount() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let url = try game.writeMod("fields.archive", records: [
        TestRecord(
            hash: 0x1111,
            payload: Data("a".utf8),
            timestamp: 0x0123456789abcdef,
            inlineBufferSegments: 3
        )
    ])

    let record = try RDARArchive.read(url).record(hash: 0x1111)!

    #expect(record.timestamp == 0x0123456789abcdef)
    #expect(record.numInlineBufferSegments == 3)
}
