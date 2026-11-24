import Foundation

public enum TweakBlobError: Error, CustomStringConvertible {
    case notATweakBlob(UInt32)
    case unknownType(UInt64)
    case truncatedSection(String, Int)
    case blockOverrun(String, Int, Int)
    case invalidSectionOffsets
    case entryCountMismatch(String, UInt32, UInt32)
    case invalidValueIndex(String, UInt32)
    case unsortedSection(String)
    case roundTripMismatch

    public var description: String {
        switch self {
        case let .notATweakBlob(magic):
            return "not a TweakDB blob: magic 0x\(String(magic, radix: 16, uppercase: true))"
        case let .unknownType(hash):
            return "type table names an unknown type, FNV-1a 64 0x\(String(hash, radix: 16, uppercase: true))"
        case let .truncatedSection(name, offset):
            return "\(name) section at offset \(offset) runs past the end of the blob"
        case let .blockOverrun(type, ended, expected):
            return "\(type) block ended at \(ended) but the next section starts at \(expected)"
        case .invalidSectionOffsets:
            return "TweakDB section offsets are not monotonic or point inside the header"
        case let .entryCountMismatch(type, declared, actual):
            return "\(type) table declares \(declared) entries but its block contains \(actual)"
        case let .invalidValueIndex(type, index):
            return "\(type) entry references value index \(index) outside its pool"
        case let .unsortedSection(name):
            return "TweakDB \(name) section is not sorted"
        case .roundTripMismatch:
            return "parsed TweakDB cannot be serialized to byte-identical input"
        }
    }
}

public struct TweakFlatEntry: Sendable, Equatable {
    public var nameHash: UInt32
    public var nameLength: UInt32
    public var valueIndex: UInt32

    public init(nameHash: UInt32, nameLength: UInt32, valueIndex: UInt32) {
        self.nameHash = nameHash
        self.nameLength = nameLength
        self.valueIndex = valueIndex
    }
}

public struct TweakTypeBlock: Sendable {
    public let type: TweakValueType
    public let typeNameHash: UInt64
    public var declaredValueCount: UInt32
    public var values: [Data]
    public var entries: [TweakFlatEntry]

    public init(
        type: TweakValueType,
        typeNameHash: UInt64,
        declaredValueCount: UInt32,
        values: [Data],
        entries: [TweakFlatEntry]
    ) {
        self.type = type
        self.typeNameHash = typeNameHash
        self.declaredValueCount = declaredValueCount
        self.values = values
        self.entries = entries
    }
}

public struct TweakRecord: Sendable, Equatable {
    public var nameHash: UInt32
    public var nameLength: UInt32
    public var recordTypeHash: UInt32

    public init(nameHash: UInt32, nameLength: UInt32, recordTypeHash: UInt32) {
        self.nameHash = nameHash
        self.nameLength = nameLength
        self.recordTypeHash = recordTypeHash
    }
}

public struct TweakQuery: Sendable, Equatable {
    public var nameHash: UInt32
    public var nameLength: UInt32
    public var members: [UInt64]

    public init(nameHash: UInt32, nameLength: UInt32, members: [UInt64]) {
        self.nameHash = nameHash
        self.nameLength = nameLength
        self.members = members
    }
}

public struct TweakGroupTag: Sendable, Equatable {
    public var nameHash: UInt32
    public var nameLength: UInt32
    public var tag: UInt8

    public init(nameHash: UInt32, nameLength: UInt32, tag: UInt8) {
        self.nameHash = nameHash
        self.nameLength = nameLength
        self.tag = tag
    }
}

public struct TweakBlob: Sendable {
    public let raw: Data
    public let magic: UInt32
    public let blobVersion: UInt32
    public let parserVersion: UInt32
    public let formatConstant: UInt32
    public let flatsOffset: UInt32
    public let recordsOffset: UInt32
    public let queriesOffset: UInt32
    public let groupTagsOffset: UInt32
    public var blocks: [TweakTypeBlock]
    public var records: [TweakRecord]
    public var queries: [TweakQuery]
    public var groupTags: [TweakGroupTag]

    public static func read(_ url: URL) throws -> TweakBlob {
        try autoreleasepool {
            try parse(try Data(contentsOf: url, options: .mappedIfSafe))
        }
    }

    public static func parse(_ data: Data) throws -> TweakBlob {
        guard data.count >= 32 else {
            throw TweakBlobError.truncatedSection("header", data.count)
        }

        let magic = try data.uint32LE(at: 0)
        guard magic == 0x0BB1_DB47 else {
            throw TweakBlobError.notATweakBlob(magic)
        }

        let flatsOffset = try data.uint32LE(at: 16)
        let recordsOffset = try data.uint32LE(at: 20)
        let queriesOffset = try data.uint32LE(at: 24)
        let groupTagsOffset = try data.uint32LE(at: 28)
        let offsets = [flatsOffset, recordsOffset, queriesOffset, groupTagsOffset]
        guard flatsOffset >= 32,
              offsets == offsets.sorted(),
              Int(groupTagsOffset) <= data.count else {
            throw TweakBlobError.invalidSectionOffsets
        }

        let typeCount = try readUInt32(data, at: Int(flatsOffset), section: "flats")
        let tableEnd = try checkedAdd(Int(flatsOffset) + 4, Int(typeCount) * 20)
        guard tableEnd <= Int(recordsOffset), tableEnd <= data.count else {
            throw TweakBlobError.truncatedSection("type table", Int(flatsOffset))
        }

        var descriptors: [(type: TweakValueType, hash: UInt64, declared: UInt32, entries: UInt32, offset: UInt32)] = []
        descriptors.reserveCapacity(Int(typeCount))
        var cursor = Int(flatsOffset) + 4
        for _ in 0..<Int(typeCount) {
            let hash = try readUInt64(data, at: cursor, section: "type table")
            guard let type = TweakValueType(typeNameHash: hash) else {
                throw TweakBlobError.unknownType(hash)
            }
            descriptors.append((
                type: type,
                hash: hash,
                declared: try readUInt32(data, at: cursor + 8, section: "type table"),
                entries: try readUInt32(data, at: cursor + 12, section: "type table"),
                offset: try readUInt32(data, at: cursor + 16, section: "type table")
            ))
            cursor += 20
        }

        if let first = descriptors.first, Int(first.offset) != tableEnd {
            throw TweakBlobError.blockOverrun(first.type.typeName, tableEnd, Int(first.offset))
        }
        for index in descriptors.indices {
            let start = Int(descriptors[index].offset)
            let end = index + 1 < descriptors.count
                ? Int(descriptors[index + 1].offset)
                : Int(recordsOffset)
            guard start >= tableEnd, start <= end, end <= data.count else {
                throw TweakBlobError.invalidSectionOffsets
            }
        }

        var blocks: [TweakTypeBlock] = []
        blocks.reserveCapacity(descriptors.count)
        for (index, descriptor) in descriptors.enumerated() {
            try autoreleasepool {
                var position = Int(descriptor.offset)
                let valueCount = try readUInt32(data, at: position, section: descriptor.type.typeName)
                position += 4

                let blockEnd = index + 1 < descriptors.count ? Int(descriptors[index + 1].offset) : Int(recordsOffset)
                let valueWidth = descriptor.type.fixedWidth ?? 1
                let valueCapacity = max(0, blockEnd - position - 4) / max(1, valueWidth)
                guard Int(valueCount) <= valueCapacity else {
                    throw TweakBlobError.truncatedSection(descriptor.type.typeName, position)
                }
                var values: [Data] = []
                values.reserveCapacity(Int(valueCount))
                for _ in 0..<Int(valueCount) {
                    let (bytes, next) = try readValue(data, at: position, type: descriptor.type)
                    values.append(bytes)
                    position = next
                }

                let actualEntryCount = try readUInt32(data, at: position, section: descriptor.type.typeName)
                position += 4
                guard actualEntryCount == descriptor.entries else {
                    throw TweakBlobError.entryCountMismatch(
                        descriptor.type.typeName,
                        descriptor.entries,
                        actualEntryCount
                    )
                }

                guard Int(actualEntryCount) <= max(0, blockEnd - position) / 12 else {
                    throw TweakBlobError.truncatedSection(descriptor.type.typeName, position)
                }
                var entries: [TweakFlatEntry] = []
                entries.reserveCapacity(Int(actualEntryCount))
                for _ in 0..<Int(actualEntryCount) {
                    let nameHash = try readUInt32(data, at: position, section: descriptor.type.typeName)
                    let nameLength = try readUInt32(data, at: position + 4, section: descriptor.type.typeName)
                    let valueIndex = try readUInt32(data, at: position + 8, section: descriptor.type.typeName)
                    guard valueIndex < valueCount else {
                        throw TweakBlobError.invalidValueIndex(descriptor.type.typeName, valueIndex)
                    }
                    entries.append(TweakFlatEntry(
                        nameHash: nameHash,
                        nameLength: nameLength,
                        valueIndex: valueIndex
                    ))
                    position += 12
                }

                let expectedEnd = index + 1 < descriptors.count
                    ? Int(descriptors[index + 1].offset)
                    : Int(recordsOffset)
                guard position == expectedEnd else {
                    throw TweakBlobError.blockOverrun(descriptor.type.typeName, position, expectedEnd)
                }

                blocks.append(TweakTypeBlock(
                    type: descriptor.type,
                    typeNameHash: descriptor.hash,
                    declaredValueCount: descriptor.declared,
                    values: values,
                    entries: entries
                ))
            }
        }

        var position = Int(recordsOffset)
        let recordCount = try readUInt32(data, at: position, section: "records")
        position += 4
        guard Int(recordCount) <= max(0, Int(queriesOffset) - position) / 12 else {
            throw TweakBlobError.truncatedSection("records", position)
        }
        var records: [TweakRecord] = []
        records.reserveCapacity(Int(recordCount))
        for _ in 0..<Int(recordCount) {
            records.append(TweakRecord(
                nameHash: try readUInt32(data, at: position, section: "records"),
                nameLength: try readUInt32(data, at: position + 4, section: "records"),
                recordTypeHash: try readUInt32(data, at: position + 8, section: "records")
            ))
            position += 12
        }
        guard position == Int(queriesOffset) else {
            throw TweakBlobError.blockOverrun("records", position, Int(queriesOffset))
        }

        position = Int(queriesOffset)
        let queryCount = try readUInt32(data, at: position, section: "queries")
        position += 4
        guard Int(queryCount) <= max(0, Int(groupTagsOffset) - position) / 12 else {
            throw TweakBlobError.truncatedSection("queries", position)
        }
        var queries: [TweakQuery] = []
        queries.reserveCapacity(Int(queryCount))
        for _ in 0..<Int(queryCount) {
            let nameHash = try readUInt32(data, at: position, section: "queries")
            let nameLength = try readUInt32(data, at: position + 4, section: "queries")
            let memberCount = try readUInt32(data, at: position + 8, section: "queries")
            position += 12
            guard Int(memberCount) <= max(0, Int(groupTagsOffset) - position) / 8 else {
                throw TweakBlobError.truncatedSection("query members", position)
            }
            var members: [UInt64] = []
            members.reserveCapacity(Int(memberCount))
            for _ in 0..<Int(memberCount) {
                members.append(try readUInt64(data, at: position, section: "queries"))
                position += 8
            }
            queries.append(TweakQuery(nameHash: nameHash, nameLength: nameLength, members: members))
        }
        guard position == Int(groupTagsOffset) else {
            throw TweakBlobError.blockOverrun("queries", position, Int(groupTagsOffset))
        }

        position = Int(groupTagsOffset)
        let tagCount = try readUInt32(data, at: position, section: "group tags")
        position += 4
        guard Int(tagCount) <= max(0, data.count - position) / 9 else {
            throw TweakBlobError.truncatedSection("group tags", position)
        }
        var groupTags: [TweakGroupTag] = []
        groupTags.reserveCapacity(Int(tagCount))
        for _ in 0..<Int(tagCount) {
            let nameHash = try readUInt32(data, at: position, section: "group tags")
            let nameLength = try readUInt32(data, at: position + 4, section: "group tags")
            guard position + 9 <= data.count else {
                throw TweakBlobError.truncatedSection("group tags", position)
            }
            groupTags.append(TweakGroupTag(
                nameHash: nameHash,
                nameLength: nameLength,
                tag: data[position + 8]
            ))
            position += 9
        }
        guard position == data.count else {
            throw TweakBlobError.blockOverrun("group tags", position, data.count)
        }

        let blob = TweakBlob(
            raw: data,
            magic: magic,
            blobVersion: try data.uint32LE(at: 4),
            parserVersion: try data.uint32LE(at: 8),
            formatConstant: try data.uint32LE(at: 12),
            flatsOffset: flatsOffset,
            recordsOffset: recordsOffset,
            queriesOffset: queriesOffset,
            groupTagsOffset: groupTagsOffset,
            blocks: blocks,
            records: records,
            queries: queries,
            groupTags: groupTags
        )
        guard TweakBlobWriter.serialize(blob) == data else {
            throw TweakBlobError.roundTripMismatch
        }
        return blob
    }

    static func readValue(_ data: Data, at offset: Int, type: TweakValueType) throws -> (Data, Int) {
        if let width = type.fixedWidth {
            guard offset >= 0, offset <= data.count, width <= data.count - offset else {
                throw TweakBlobError.truncatedSection(type.typeName, offset)
            }
            return (data.subdata(in: offset..<offset + width), offset + width)
        }
        if type.isStringLike {
            let (length, next) = try TweakPacked.read(data, at: offset)
            guard length >= 0, next <= data.count, length <= data.count - next else {
                throw TweakBlobError.truncatedSection(type.typeName, offset)
            }
            return (data.subdata(in: offset..<next + length), next + length)
        }
        guard let element = type.elementType else {
            throw TweakBlobError.unknownType(0)
        }
        let (count, start) = try TweakPacked.read(data, at: offset)
        var cursor = start
        for _ in 0..<count {
            cursor = try readValue(data, at: cursor, type: element).1
        }
        guard cursor <= data.count else {
            throw TweakBlobError.truncatedSection(type.typeName, offset)
        }
        return (data.subdata(in: offset..<cursor), cursor)
    }

    public static func tweakDBID(_ name: String) -> (hash: UInt32, length: UInt32) {
        (Hashes.crc32(Data(name.utf8)), UInt32(name.utf8.count))
    }

    public func find(flat name: String) -> (blockIndex: Int, entryIndex: Int)? {
        let id = Self.tweakDBID(name)
        for (blockIndex, block) in blocks.enumerated() {
            var low = 0
            var high = block.entries.count
            while low < high {
                let middle = (low + high) / 2
                let entry = block.entries[middle]
                if (entry.nameHash, entry.nameLength) == (id.hash, id.length) {
                    return (blockIndex, middle)
                }
                if (entry.nameHash, entry.nameLength) < (id.hash, id.length) {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
        }
        return nil
    }

    public func record(named name: String) -> Int? {
        let id = Self.tweakDBID(name)
        return records.firstIndex { ($0.nameHash, $0.nameLength) == (id.hash, id.length) }
    }
}

private func checkedAdd(_ left: Int, _ right: Int) throws -> Int {
    guard right >= 0, left >= 0, left <= Int.max - right else {
        throw TweakBlobError.invalidSectionOffsets
    }
    return left + right
}

private func readUInt32(_ data: Data, at offset: Int, section: String) throws -> UInt32 {
    guard offset >= 0, offset <= data.count, 4 <= data.count - offset else {
        throw TweakBlobError.truncatedSection(section, offset)
    }
    return try data.uint32LE(at: offset)
}

private func readUInt64(_ data: Data, at offset: Int, section: String) throws -> UInt64 {
    guard offset >= 0, offset <= data.count, 8 <= data.count - offset else {
        throw TweakBlobError.truncatedSection(section, offset)
    }
    return try data.uint64LE(at: offset)
}

public extension Hashes {
    static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0..<256 {
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 0 ? value >> 1 : 0xEDB8_8320 ^ (value >> 1)
            }
            table[index] = value
        }

        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
