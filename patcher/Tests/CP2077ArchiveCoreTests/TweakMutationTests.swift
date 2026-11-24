import CP2077ArchiveCore
import Foundation
import Testing

private func mutationInt32(_ value: Int32) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
}

@Test func insertingIntoAPoolPlacesTheValueInSortedPosition() throws {
    var blob = try TweakBlob.parse(makeSampleBlob().build())
    let block = try #require(blob.blockIndex(for: .int32))
    let index = try blob.insertValue(mutationInt32(8), inBlock: block)

    #expect(index == 2)
    #expect(blob.blocks[block].values.count == 4)
    #expect(try TweakValueOrder.isSorted(blob.blocks[block].values, type: .int32))
}

@Test func insertingAValueAlreadyPooledReturnsItsIndexAndAddsNothing() throws {
    var blob = try TweakBlob.parse(makeSampleBlob().build())
    let block = try #require(blob.blockIndex(for: .int32))
    let before = blob.blocks[block].values.count

    #expect(try blob.insertValue(mutationInt32(7), inBlock: block) == 1)
    #expect(blob.blocks[block].values.count == before)
}

@Test func insertionReindexesEveryEntryAtOrPastTheInsertionPoint() throws {
    var builder = makeSampleBlob()
    builder.blocks[1].entries = [
        (name: "Items.Widget.power", valueIndex: 0),
        (name: "Items.Gadget.power", valueIndex: 2),
    ].sorted {
        let left = TweakBlobBuilder.tweakDBID($0.name)
        let right = TweakBlobBuilder.tweakDBID($1.name)
        return (left.hash, left.length) < (right.hash, right.length)
    }
    var blob = try TweakBlob.parse(builder.build())
    let block = try #require(blob.blockIndex(for: .int32))

    _ = try blob.insertValue(mutationInt32(8), inBlock: block)

    let widget = try #require(blob.find(flat: "Items.Widget.power"))
    let gadget = try #require(blob.find(flat: "Items.Gadget.power"))
    #expect(blob.blocks[widget.blockIndex].entries[widget.entryIndex].valueIndex == 0)
    #expect(blob.blocks[gadget.blockIndex].entries[gadget.entryIndex].valueIndex == 3)
}

@Test func assignRepointsAnExistingFlatAndKeepsTheBlobParseable() throws {
    var blob = try TweakBlob.parse(makeSampleBlob().build())
    let replacement = TweakPacked.encode(5) + Data("omega".utf8)
    try blob.assign(flat: "Items.Widget.friendlyName", value: replacement)

    let bytes = TweakBlobWriter.serialize(blob)
    let reparsed = try TweakBlob.parse(bytes)
    let located = try #require(reparsed.find(flat: "Items.Widget.friendlyName"))
    let stored = reparsed.blocks[located.blockIndex]
        .values[Int(reparsed.blocks[located.blockIndex].entries[located.entryIndex].valueIndex)]
    #expect(stored == replacement)
    #expect(try TweakValueOrder.isSorted(reparsed.blocks[located.blockIndex].values, type: .string))
}

@Test func assigningToAnAbsentFlatThrows() throws {
    var blob = try TweakBlob.parse(makeSampleBlob().build())
    #expect(throws: TweakMutationError.self) {
        try blob.assign(flat: "Items.Missing.friendlyName", value: mutationInt32(1))
    }
}
