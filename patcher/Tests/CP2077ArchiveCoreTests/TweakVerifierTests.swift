import CP2077ArchiveCore
import Foundation
import Testing

@Test func verifierAcceptsAParsedAndRewrittenBlob() throws {
    let blob = try TweakBlob.parse(makeSampleBlob().build())
    let report = TweakVerifier.verify(blob)

    #expect(report.isValid)
    #expect(report.issues.isEmpty)
}

@Test func verifierAcceptsExistingFlatMutationAfterSerialization() throws {
    var blob = try TweakBlob.parse(makeSampleBlob().build())
    try blob.assign(
        flat: "Items.Widget.friendlyName",
        value: TweakPacked.encode(5) + Data("omega".utf8)
    )

    let report = TweakVerifier.verify(blob)

    #expect(report.isValid)
}

@Test func verifierAcceptsEngineOrderedCNameAndUnsupportedColorPools() throws {
    func packed(_ text: String) -> Data {
        TweakPacked.encode(text.utf8.count) + Data(text.utf8)
    }

    var builder = makeSampleBlob()
    builder.blocks.append(.init(
        type: .cname,
        values: [packed("Bravo"), packed("Alpha")],
        entries: []
    ))
    builder.blocks.append(.init(
        type: .color,
        values: [Data(repeating: 0, count: 16), Data(repeating: 1, count: 16)],
        entries: []
    ))

    let report = TweakVerifier.verify(try TweakBlob.parse(builder.build()))

    #expect(report.isValid)
}

@Test func verifierReportsAnUnsortedEntryList() throws {
    var blob = try TweakBlob.parse(makeSampleBlob().build())
    blob.blocks[0].entries.swapAt(0, 1)

    let report = TweakVerifier.verify(blob)

    #expect(!report.isValid)
    #expect(report.issues.contains { $0.contains("entries") })
    #expect(throws: TweakVerificationError.self) {
        try TweakVerifier.validate(blob)
    }
}

@Test func verifierReportsAnOutOfRangeValueIndex() throws {
    var blob = try TweakBlob.parse(makeSampleBlob().build())
    blob.blocks[0].entries[0].valueIndex = 99

    let report = TweakVerifier.verify(blob)

    #expect(!report.isValid)
    #expect(report.issues.contains { $0.contains("String") && $0.contains("99") })
}

@Test func verifierReportsMalformedInputWithoutLaunchingOrWriting() {
    let report = TweakVerifier.verify(data: Data([0x47, 0xDB, 0xB1]))

    #expect(!report.isValid)
    #expect(report.issues.contains { $0.contains("header") })
}
