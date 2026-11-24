import Foundation

public enum TweakBlobWriter {
    public static func serialize(_ blob: TweakBlob) -> Data {
        func u32(_ value: UInt32) -> Data {
            withUnsafeBytes(of: value.littleEndian) { Data($0) }
        }
        func u64(_ value: UInt64) -> Data {
            withUnsafeBytes(of: value.littleEndian) { Data($0) }
        }

        var bodies: [Data] = []
        bodies.reserveCapacity(blob.blocks.count)
        for block in blob.blocks {
            autoreleasepool {
                var body = Data()
                body.reserveCapacity(block.values.reduce(8) { $0 + $1.count } + block.entries.count * 12)
                body.append(u32(UInt32(block.values.count)))
                for value in block.values {
                    body.append(value)
                }
                body.append(u32(UInt32(block.entries.count)))
                for entry in block.entries {
                    body.append(u32(entry.nameHash))
                    body.append(u32(entry.nameLength))
                    body.append(u32(entry.valueIndex))
                }
                bodies.append(body)
            }
        }

        let flatsOffset = Int(blob.flatsOffset)
        var cursor = flatsOffset + 4 + blob.blocks.count * 20
        var table = Data()
        table.reserveCapacity(blob.blocks.count * 20)
        for (index, block) in blob.blocks.enumerated() {
            table.append(u64(block.typeNameHash))
            table.append(u32(block.declaredValueCount))
            table.append(u32(UInt32(block.entries.count)))
            table.append(u32(UInt32(cursor)))
            cursor += bodies[index].count
        }
        let recordsOffset = cursor

        var recordSection = u32(UInt32(blob.records.count))
        for record in blob.records {
            recordSection.append(u32(record.nameHash))
            recordSection.append(u32(record.nameLength))
            recordSection.append(u32(record.recordTypeHash))
        }
        let queriesOffset = recordsOffset + recordSection.count

        var querySection = u32(UInt32(blob.queries.count))
        for query in blob.queries {
            querySection.append(u32(query.nameHash))
            querySection.append(u32(query.nameLength))
            querySection.append(u32(UInt32(query.members.count)))
            for member in query.members {
                querySection.append(u64(member))
            }
        }
        let groupTagsOffset = queriesOffset + querySection.count

        var tagSection = u32(UInt32(blob.groupTags.count))
        for tag in blob.groupTags {
            tagSection.append(u32(tag.nameHash))
            tagSection.append(u32(tag.nameLength))
            tagSection.append(Data([tag.tag]))
        }

        var out = Data()
        out.reserveCapacity(groupTagsOffset + tagSection.count)
        out.append(u32(blob.magic))
        out.append(u32(blob.blobVersion))
        out.append(u32(blob.parserVersion))
        out.append(u32(blob.formatConstant))
        out.append(u32(UInt32(flatsOffset)))
        out.append(u32(UInt32(recordsOffset)))
        out.append(u32(UInt32(queriesOffset)))
        out.append(u32(UInt32(groupTagsOffset)))
        out.append(u32(UInt32(blob.blocks.count)))
        out.append(table)
        for body in bodies {
            out.append(body)
        }
        out.append(recordSection)
        out.append(querySection)
        out.append(tagSection)
        return out
    }

    public static func write(_ blob: TweakBlob, to url: URL) throws {
        try autoreleasepool {
            try serialize(blob).write(to: url, options: .atomic)
        }
    }
}
