import CP2077ArchiveCore
import Foundation

struct TweakBlobBuilder {
    struct Block {
        var type: TweakValueType
        var declaredValueCount: UInt32?
        var values: [Data]
        var entries: [(name: String, valueIndex: UInt32)]
    }

    var blocks: [Block] = []
    var records: [(name: String, typeHash: UInt32)] = []
    var queries: [(name: String, members: [UInt64])] = []
    var groupTags: [(name: String, tag: UInt8)] = []
    var formatConstant: UInt32 = 0x69DE_CA93

    static func tweakDBID(_ name: String) -> (hash: UInt32, length: UInt32) {
        (Hashes.crc32(Data(name.utf8)), UInt32(name.utf8.count))
    }

    private static func u32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func u64(_ value: UInt64) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    func build() -> Data {
        var blockBodies: [Data] = []
        for block in blocks {
            var body = Self.u32(UInt32(block.values.count))
            for value in block.values { body.append(value) }
            body.append(Self.u32(UInt32(block.entries.count)))
            for entry in block.entries {
                let id = Self.tweakDBID(entry.name)
                body.append(Self.u32(id.hash))
                body.append(Self.u32(id.length))
                body.append(Self.u32(entry.valueIndex))
            }
            blockBodies.append(body)
        }

        let flatsOffset = 32
        var cursor = flatsOffset + 4 + blocks.count * 20
        var table = Data()
        for (index, block) in blocks.enumerated() {
            table.append(Self.u64(Hashes.fnv1a64(block.type.typeName)))
            table.append(Self.u32(block.declaredValueCount ?? UInt32(block.values.count)))
            table.append(Self.u32(UInt32(block.entries.count)))
            table.append(Self.u32(UInt32(cursor)))
            cursor += blockBodies[index].count
        }
        let recordsOffset = cursor

        var recordSection = Self.u32(UInt32(records.count))
        for record in records {
            let id = Self.tweakDBID(record.name)
            recordSection.append(Self.u32(id.hash))
            recordSection.append(Self.u32(id.length))
            recordSection.append(Self.u32(record.typeHash))
        }
        let queriesOffset = recordsOffset + recordSection.count

        var querySection = Self.u32(UInt32(queries.count))
        for query in queries {
            let id = Self.tweakDBID(query.name)
            querySection.append(Self.u32(id.hash))
            querySection.append(Self.u32(id.length))
            querySection.append(Self.u32(UInt32(query.members.count)))
            for member in query.members { querySection.append(Self.u64(member)) }
        }
        let groupTagsOffset = queriesOffset + querySection.count

        var tagSection = Self.u32(UInt32(groupTags.count))
        for tag in groupTags {
            let id = Self.tweakDBID(tag.name)
            tagSection.append(Self.u32(id.hash))
            tagSection.append(Self.u32(id.length))
            tagSection.append(Data([tag.tag]))
        }

        var out = Data()
        out.append(Self.u32(0x0BB1_DB47))
        out.append(Self.u32(8))
        out.append(Self.u32(4))
        out.append(Self.u32(formatConstant))
        out.append(Self.u32(UInt32(flatsOffset)))
        out.append(Self.u32(UInt32(recordsOffset)))
        out.append(Self.u32(UInt32(queriesOffset)))
        out.append(Self.u32(UInt32(groupTagsOffset)))
        out.append(Self.u32(UInt32(blocks.count)))
        out.append(table)
        for body in blockBodies { out.append(body) }
        out.append(recordSection)
        out.append(querySection)
        out.append(tagSection)
        return out
    }
}

func makeSampleBlob() -> TweakBlobBuilder {
    func packedString(_ text: String) -> Data {
        TweakPacked.encode(text.utf8.count) + Data(text.utf8)
    }
    func int32(_ value: Int32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    var builder = TweakBlobBuilder()
    var strings = ["alpha", "bravo", "delta"].map(packedString)
    strings.sort { $0.dropFirst().lexicographicallyPrecedes($1.dropFirst()) }

    builder.blocks = [
        .init(type: .string, declaredValueCount: nil, values: strings, entries: []),
        .init(type: .int32, declaredValueCount: nil, values: [int32(1), int32(7), int32(9)], entries: []),
        .init(type: .bool, declaredValueCount: nil, values: [Data([0]), Data([1])], entries: []),
    ]

    var stringEntries = [
        (name: "Items.Widget.friendlyName", valueIndex: UInt32(0)),
        (name: "Items.Gadget.friendlyName", valueIndex: UInt32(1)),
    ]
    stringEntries.sort {
        let left = TweakBlobBuilder.tweakDBID($0.name)
        let right = TweakBlobBuilder.tweakDBID($1.name)
        return (left.hash, left.length) < (right.hash, right.length)
    }
    builder.blocks[0].entries = stringEntries

    var records = [
        (name: "Items.Widget", typeHash: UInt32(0x7FDE_F930)),
        (name: "Items.Gadget", typeHash: UInt32(0x7FDE_F930)),
    ]
    records.sort { TweakBlobBuilder.tweakDBID($0.name).hash < TweakBlobBuilder.tweakDBID($1.name).hash }
    builder.records = records
    return builder
}
