import CP2077ArchiveCore
import Foundation
import Testing

private let tweakSource = URL(fileURLWithPath: "/tmp/mod.yaml")

@Test func assignsScalarsOnAnExistingRecord() throws {
    let operations = try TweakDocument.parse("""
    Items.Preset_Lexington_Wilson:
      friendlyName: "wilson_special"
      damage: 42
      isValid: true
      weight: 1.5
    """, source: tweakSource)

    #expect(operations.count == 4)
    #expect(operations.contains {
        if case let .assign(flat, _, .string(value)) = $0 {
            return flat == "Items.Preset_Lexington_Wilson.friendlyName" && value == "wilson_special"
        }
        return false
    })
    #expect(operations.contains {
        if case let .assign(flat, _, .int(value)) = $0 {
            return flat == "Items.Preset_Lexington_Wilson.damage" && value == 42
        }
        return false
    })
}

@Test func flatteningUsesRecordDotProperty() throws {
    let operations = try TweakDocument.parse("""
    Items.Widget:
      power: 7
    """, source: tweakSource)

    guard case let .assign(flat, _, _) = operations[0] else {
        Issue.record("expected an assignment")
        return
    }
    #expect(flat == "Items.Widget.power")
}

@Test func arrayAppendAndRemoveAreDistinctOperations() throws {
    let operations = try TweakDocument.parse("""
    Items.Widget:
      tags: !append
        - Alpha
        - Bravo
      oldTags: !remove
        - Charlie
    """, source: tweakSource)

    #expect(operations.contains {
        if case let .arrayAppend(flat, _, elements) = $0 {
            return flat == "Items.Widget.tags" && elements.count == 2
        }
        return false
    })
    #expect(operations.contains {
        if case let .arrayRemove(flat, _, elements) = $0 {
            return flat == "Items.Widget.oldTags" && elements.count == 1
        }
        return false
    })
}

@Test func newRecordDirectivesAreRejectedByTheExistingFlatSubset() throws {
    #expect(throws: TweakDocumentError.self) {
        try TweakDocument.parse("""
        Items.MyNewGun:
          $type: Items.Preset_Lexington_Wilson
          friendlyName: "my_new_gun"
        """, source: tweakSource)
    }
}

@Test func malformedAndTopLevelScalarYAMLIsRejected() throws {
    #expect(throws: TweakDocumentError.self) {
        try TweakDocument.parse("this: [is: not: valid", source: tweakSource)
    }
    #expect(throws: TweakDocumentError.self) {
        try TweakDocument.parse("just a string", source: tweakSource)
    }
}

@Test func unsupportedNestedMappingsAreRejectedRatherThanMisread() throws {
    #expect(throws: TweakDocumentError.self) {
        try TweakDocument.parse("""
        Items.Widget:
          property:
            nested: value
        """, source: tweakSource)
    }
}

@Test func selectorsNormalizeDefaultBaseAndEp1Operations() throws {
    let operations = try TweakDocument.parse("""
    Items.Widget:
      defaultPower: 1
      basePower:
        base: 2
      ep1Power:
        ep1: 3
      tags:
        base: !append
          - Alpha
      oldTags:
        ep1: !remove
          - Bravo
    """, source: tweakSource)

    #expect(operations.contains {
        if case let .assign(flat, selector, .int(value)) = $0 {
            return flat == "Items.Widget.defaultPower" && selector == nil && value == 1
        }
        return false
    })
    #expect(operations.contains {
        if case let .assign(flat, selector, .int(value)) = $0 {
            return flat == "Items.Widget.basePower" && selector == .base && value == 2
        }
        return false
    })
    #expect(operations.contains {
        if case let .assign(flat, selector, .int(value)) = $0 {
            return flat == "Items.Widget.ep1Power" && selector == .ep1 && value == 3
        }
        return false
    })
    #expect(operations.contains {
        if case let .arrayAppend(flat, selector, elements) = $0 {
            return flat == "Items.Widget.tags" && selector == .base && elements == [.string("Alpha")]
        }
        return false
    })
    #expect(operations.contains {
        if case let .arrayRemove(flat, selector, elements) = $0 {
            return flat == "Items.Widget.oldTags" && selector == .ep1 && elements == [.string("Bravo")]
        }
        return false
    })
}

@Test func unknownBlobSelectorsAreRejected() throws {
    #expect(throws: TweakDocumentError.self) {
        try TweakDocument.parse("""
        Items.Widget:
          power:
            dlc: 7
        """, source: tweakSource)
    }
}
