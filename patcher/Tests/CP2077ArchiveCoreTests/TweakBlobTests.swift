import CP2077ArchiveCore
import Foundation
import Testing

@Test func parsesHeaderAndEverySection() throws {
    let blob = try TweakBlob.parse(makeSampleBlob().build())

    #expect(blob.magic == 0x0BB1_DB47)
    #expect(blob.blobVersion == 8)
    #expect(blob.parserVersion == 4)
    #expect(blob.formatConstant == 0x69DE_CA93)
    #expect(blob.blocks.count == 3)
    #expect(blob.blocks[0].type == .string)
    #expect(blob.blocks[0].values.count == 3)
    #expect(blob.blocks[0].entries.count == 2)
    #expect(blob.records.count == 2)
}

@Test func resolvesAFlatByNameThroughHashAndLength() throws {
    let blob = try TweakBlob.parse(makeSampleBlob().build())
    let located = try #require(blob.find(flat: "Items.Widget.friendlyName"))
    #expect(located.blockIndex == 0)

    let entry = blob.blocks[located.blockIndex].entries[located.entryIndex]
    let value = blob.blocks[located.blockIndex].values[Int(entry.valueIndex)]
    let content = try TweakPacked.read(value, at: 0).next
    #expect(String(decoding: value[content...], as: UTF8.self) == "alpha")

    #expect(blob.find(flat: "Items.Nonexistent.friendlyName") == nil)
}

@Test func refusesAFileThatIsNotATweakBlob() throws {
    var bytes = makeSampleBlob().build()
    bytes[0] = 0xFF
    #expect(throws: TweakBlobError.self) { try TweakBlob.parse(bytes) }
}

@Test func parseRejectsBytesThatDoNotRoundTripIdentically() throws {
    func uint32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<offset + 4].enumerated().reduce(0) { value, byte in
            value | UInt32(byte.element) << UInt32(byte.offset * 8)
        }
    }

    var bytes = makeSampleBlob().build()
    bytes.insert(0, at: 32)
    for offset in stride(from: 16, through: 28, by: 4) {
        let shifted = uint32(bytes, at: offset) + 1
        try bytes.writeUInt32LEForTest(shifted, at: offset)
    }
    let typeCount = Int(uint32(bytes, at: 33))
    for index in 0..<typeCount {
        let descriptorOffset = 37 + index * 20 + 16
        let shifted = uint32(bytes, at: descriptorOffset) + 1
        try bytes.writeUInt32LEForTest(shifted, at: descriptorOffset)
    }

    #expect(throws: TweakBlobError.self) { try TweakBlob.parse(bytes) }
}
