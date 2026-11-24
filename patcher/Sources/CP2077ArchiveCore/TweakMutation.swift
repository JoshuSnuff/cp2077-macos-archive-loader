import Foundation

public enum TweakMutationError: Error, CustomStringConvertible {
    case noSuchFlat(String)
    case noSuchBlock(TweakValueType)
    case invalidBlockIndex(Int)

    public var description: String {
        switch self {
        case let .noSuchFlat(name):
            return "no flat named \(name) exists in this blob"
        case let .noSuchBlock(type):
            return "this blob has no \(type.typeName) block"
        case let .invalidBlockIndex(index):
            return "TweakDB block index \(index) is outside this blob"
        }
    }
}

public extension TweakBlob {
    func blockIndex(for type: TweakValueType) -> Int? {
        blocks.firstIndex { $0.type == type }
    }

    mutating func insertValue(_ value: Data, inBlock blockIndex: Int) throws -> UInt32 {
        guard blocks.indices.contains(blockIndex) else {
            throw TweakMutationError.invalidBlockIndex(blockIndex)
        }

        let type = blocks[blockIndex].type
        let values = blocks[blockIndex].values
        let position = try TweakValueOrder.insertionIndex(for: value, in: values, type: type)

        if position < values.count,
           try TweakValueOrder.compare(values[position], value, type: type) == 0 {
            return UInt32(position)
        }

        blocks[blockIndex].values.insert(value, at: position)
        if blocks[blockIndex].declaredValueCount < UInt32(blocks[blockIndex].values.count) {
            blocks[blockIndex].declaredValueCount = UInt32(blocks[blockIndex].values.count)
        }

        let threshold = UInt32(position)
        for index in blocks[blockIndex].entries.indices {
            if blocks[blockIndex].entries[index].valueIndex >= threshold {
                blocks[blockIndex].entries[index].valueIndex += 1
            }
        }
        return threshold
    }

    mutating func assign(flat name: String, value: Data) throws {
        guard let located = find(flat: name) else {
            throw TweakMutationError.noSuchFlat(name)
        }
        let index = try insertValue(value, inBlock: located.blockIndex)
        blocks[located.blockIndex].entries[located.entryIndex].valueIndex = index
    }
}
