import CP2077ArchiveCore
import Foundation
import Testing

@Test func packedIntegerDecodesTheMeasuredExamples() throws {
    #expect(try TweakPacked.read(Data([0xB1]), at: 0).value == 49)
    #expect(try TweakPacked.read(Data([0xB1]), at: 0).next == 1)

    #expect(try TweakPacked.read(Data([0xCF, 0x01]), at: 0).value == 79)
    #expect(try TweakPacked.read(Data([0xCF, 0x01]), at: 0).next == 2)
}

@Test func packedIntegerRejectsOverflowAndExcessiveLength() throws {
    let tooLong = Data([0xC0] + Array(repeating: UInt8(0x80), count: 9))
    #expect(throws: TweakPackedError.self) {
        try TweakPacked.read(tooLong, at: 0)
    }

    let tooWide = Data([0xC0] + Array(repeating: UInt8(0x80), count: 8) + [0x02])
    #expect(throws: TweakPackedError.self) {
        try TweakPacked.read(tooWide, at: 0)
    }
}

@Test func typeTableResolvesEveryShippedTypeName() throws {
    #expect(TweakValueType(typeNameHash: Hashes.fnv1a64("Float"))?.typeName == "Float")
    #expect(TweakValueType(typeNameHash: Hashes.fnv1a64("array:TweakDBID"))?.typeName == "array:TweakDBID")
    #expect(TweakValueType(typeNameHash: Hashes.fnv1a64("raRef:CResource"))?.typeName == "raRef:CResource")
    #expect(TweakValueType(typeNameHash: 0xDEAD_BEEF) == nil)
}

@Test func fixedWidthsMatchTheMeasuredLayout() {
    #expect(TweakValueType.bool.fixedWidth == 1)
    #expect(TweakValueType.int32.fixedWidth == 4)
    #expect(TweakValueType.tweakDBID.fixedWidth == 8)
    #expect(TweakValueType.vector3.fixedWidth == 12)
    #expect(TweakValueType.color.fixedWidth == 16)
    #expect(TweakValueType.cname.fixedWidth == nil)
    #expect(TweakValueType.cname.isStringLike)
    #expect(TweakValueType.string.isStringLike)
}
