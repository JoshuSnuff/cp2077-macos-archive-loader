import CP2077ArchiveCore
import Foundation
import Testing

private func int32(_ value: Int32) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
}

private func float(_ value: Float) -> Data {
    withUnsafeBytes(of: value.bitPattern.littleEndian) { Data($0) }
}

private func u64(_ value: UInt64) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
}

private func packed(_ text: String) -> Data {
    TweakPacked.encode(text.utf8.count) + Data(text.utf8)
}

@Test func int32OrdersSignedNotUnsigned() throws {
    #expect(try TweakValueOrder.precedes(int32(-1), int32(0), type: .int32))
    #expect(try TweakValueOrder.precedes(int32(1), int32(7), type: .int32))
    #expect(try !TweakValueOrder.precedes(int32(9), int32(7), type: .int32))
}

@Test func stringOrdersOverContentNotTheLengthPrefix() throws {
    #expect(try TweakValueOrder.precedes(packed("aaa"), packed("zz"), type: .string))
    #expect(try !TweakValueOrder.precedes(packed("zz"), packed("aaa"), type: .string))
}

@Test func tweakDBIDOrdersAsTwoU32FieldsNotAsOneU64() throws {
    let lowHashLongName = u64(0x0000_0005_0000_0001)
    let highHashShortName = u64(0x0000_0002_0000_0009)
    #expect(try TweakValueOrder.precedes(lowHashLongName, highHashShortName, type: .tweakDBID))
}

@Test func cnameSortsByFNVOverStoredBytes() throws {
    let a = packed("Alpha")
    let b = packed("Bravo")
    let expected = Hashes.fnv1a64(Data("Alpha".utf8)) < Hashes.fnv1a64(Data("Bravo".utf8))
    #expect(try TweakValueOrder.precedes(a, b, type: .cname) == expected)
}

@Test func cnameNonePinsToIndexZero() throws {
    let none = packed("None")
    let other = packed("Alpha")
    #expect(try TweakValueOrder.precedes(none, other, type: .cname))
    #expect(try !TweakValueOrder.precedes(other, none, type: .cname))
}

@Test func arraysOrderByCountThenElements() throws {
    let one = TweakPacked.encode(1, wideFlag: false) + int32(9)
    let two = TweakPacked.encode(2, wideFlag: false) + int32(1) + int32(2)
    #expect(try TweakValueOrder.precedes(one, two, type: .array(.int32)))

    let twoLow = TweakPacked.encode(2, wideFlag: false) + int32(1) + int32(2)
    let twoHigh = TweakPacked.encode(2, wideFlag: false) + int32(1) + int32(3)
    #expect(try TweakValueOrder.precedes(twoLow, twoHigh, type: .array(.int32)))
}

@Test func colorIsRefusedBecauseNoValueEverExercisesIt() throws {
    let sixteen = Data(repeating: 0, count: 16)
    #expect(throws: TweakValueOrderError.self) {
        try TweakValueOrder.precedes(sixteen, sixteen, type: .color)
    }
}

@Test func colorIsRefusedBeforePoolShortcuts() throws {
    let sixteen = Data(repeating: 0, count: 16)
    #expect(throws: TweakValueOrderError.self) {
        try TweakValueOrder.isSorted([], type: .color)
    }
    #expect(throws: TweakValueOrderError.self) {
        try TweakValueOrder.isSorted([sixteen], type: .color)
    }
    #expect(throws: TweakValueOrderError.self) {
        try TweakValueOrder.insertionIndex(for: sixteen, in: [], type: .color)
    }
    #expect(throws: TweakValueOrderError.self) {
        try TweakValueOrder.insertionIndex(for: sixteen, in: [sixteen], type: .color)
    }
}

@Test func fixedWidthComparatorsRejectMalformedValues() throws {
    #expect(throws: TweakValueOrderError.self) {
        try TweakValueOrder.precedes(Data(repeating: 0, count: 5), Data(repeating: 0, count: 4), type: .int32)
    }
    #expect(throws: TweakValueOrderError.self) {
        try TweakValueOrder.precedes(Data(repeating: 0, count: 3), Data(repeating: 0, count: 4), type: .float)
    }
    #expect(throws: TweakValueOrderError.self) {
        try TweakValueOrder.precedes(Data(repeating: 0, count: 9), Data(repeating: 0, count: 8), type: .tweakDBID)
    }
}

@Test func nonASCIICNameIsRefusedRatherThanGuessed() throws {
    #expect(throws: TweakValueOrderError.self) {
        try TweakValueOrder.insertionIndex(
            for: packed("Capitán"),
            in: [packed("Alpha")],
            type: .cname
        )
    }
}

@Test func insertionIndexLandsAtTheSortedPosition() throws {
    let pool = [int32(1), int32(7), int32(9)]
    #expect(try TweakValueOrder.insertionIndex(for: int32(0), in: pool, type: .int32) == 0)
    #expect(try TweakValueOrder.insertionIndex(for: int32(8), in: pool, type: .int32) == 2)
    #expect(try TweakValueOrder.insertionIndex(for: int32(99), in: pool, type: .int32) == 3)
}
