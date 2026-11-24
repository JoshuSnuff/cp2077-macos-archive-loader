import CP2077ArchiveCore
import Foundation
import Testing

@Test func roundTripIsByteIdentical() throws {
    let original = makeSampleBlob().build()
    let blob = try TweakBlob.parse(original)
    #expect(TweakBlobWriter.serialize(blob) == original)
}

@Test func roundTripSurvivesADeclaredCountThatExceedsTheRealOne() throws {
    var builder = makeSampleBlob()
    builder.blocks[1].declaredValueCount = 99
    let original = builder.build()

    let blob = try TweakBlob.parse(original)
    #expect(blob.blocks[1].declaredValueCount == 99)
    #expect(blob.blocks[1].values.count == 3)
    #expect(TweakBlobWriter.serialize(blob) == original)
}

@Test func serializingRecomputesEverySectionOffset() throws {
    var builder = makeSampleBlob()
    builder.blocks[0].values.append(TweakPacked.encode(5) + Data("extra".utf8))
    let grown = try TweakBlob.parse(builder.build())
    let bytes = TweakBlobWriter.serialize(grown)

    let reparsed = try TweakBlob.parse(bytes)
    #expect(reparsed.blocks[0].values.count == 4)
    #expect(TweakBlobWriter.serialize(reparsed) == bytes)
}
