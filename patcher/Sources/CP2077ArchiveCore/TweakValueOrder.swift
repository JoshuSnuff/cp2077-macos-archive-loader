import Foundation

public enum TweakValueOrderError: Error, CustomStringConvertible {
    case unsupportedType(TweakValueType)
    case nonASCIICName(String)
    case poolNotSorted(TweakValueType)
    case malformedValue(TweakValueType)

    public var description: String {
        switch self {
        case let .unsupportedType(type):
            return "\(type.typeName) values are unsupported: the shipped blobs contain none"
        case let .nonASCIICName(name):
            return "CName '\(name)' is not ASCII and cannot be inserted safely"
        case let .poolNotSorted(type):
            return "the existing \(type.typeName) pool is not sorted under the assumed comparator"
        case let .malformedValue(type):
            return "the value for \(type.typeName) is malformed"
        }
    }
}

public enum TweakValueOrder {
    public static func equivalent(_ left: Data, _ right: Data, type: TweakValueType) throws -> Bool {
        try compare(left, right, type: type) == 0
    }

    public static func precedes(_ left: Data, _ right: Data, type: TweakValueType) throws -> Bool {
        try compare(left, right, type: type) < 0
    }

    static func compare(_ left: Data, _ right: Data, type: TweakValueType) throws -> Int {
        switch type {
        case .color:
            throw TweakValueOrderError.unsupportedType(.color)

        case .int32:
            let l = Int32(bitPattern: try valueUInt32(left, type: type))
            let r = Int32(bitPattern: try valueUInt32(right, type: type))
            return l == r ? 0 : (l < r ? -1 : 1)

        case .float:
            let l = Float(bitPattern: try valueUInt32(left, type: type))
            let r = Float(bitPattern: try valueUInt32(right, type: type))
            if l == r { return 0 }
            if l.isNaN { return 1 }
            if r.isNaN { return -1 }
            return l < r ? -1 : 1

        case .bool:
            guard left.count == 1, right.count == 1 else {
                throw TweakValueOrderError.malformedValue(type)
            }
            return Int(left[left.startIndex]) - Int(right[right.startIndex])

        case .raRefCResource, .locKeyWrapper:
            let l = try valueUInt64(left, type: type)
            let r = try valueUInt64(right, type: type)
            return l == r ? 0 : (l < r ? -1 : 1)

        case .tweakDBID:
            let lh = try valueUInt32(left, type: type)
            let ll = try valueUInt32(left, at: 4, type: type)
            let rh = try valueUInt32(right, type: type)
            let rl = try valueUInt32(right, at: 4, type: type)
            if lh != rh { return lh < rh ? -1 : 1 }
            return ll == rl ? 0 : (ll < rl ? -1 : 1)

        case .string:
            return try compareBytes(content(of: left, type: type), content(of: right, type: type))

        case .cname:
            let leftBytes = try content(of: left, type: type)
            let rightBytes = try content(of: right, type: type)
            let leftName = String(decoding: leftBytes, as: UTF8.self)
            let rightName = String(decoding: rightBytes, as: UTF8.self)
            if leftName == rightName { return 0 }
            if leftName == "None" { return -1 }
            if rightName == "None" { return 1 }
            let leftHash = Hashes.fnv1a64(Data(leftBytes))
            let rightHash = Hashes.fnv1a64(Data(rightBytes))
            if leftHash != rightHash { return leftHash < rightHash ? -1 : 1 }
            return compareBytes(leftBytes, rightBytes)

        case .vector2, .vector3, .eulerAngles, .quaternion:
            guard let width = type.fixedWidth,
                  left.count == width,
                  right.count == width else {
                throw TweakValueOrderError.malformedValue(type)
            }
            let componentCount = width / 4
            for index in 0..<componentCount {
                let l = Float(bitPattern: try valueUInt32(left, at: index * 4, type: type))
                let r = Float(bitPattern: try valueUInt32(right, at: index * 4, type: type))
                if l == r { continue }
                if l.isNaN { return 1 }
                if r.isNaN { return -1 }
                return l < r ? -1 : 1
            }
            return 0

        case let .array(element):
            let (leftCount, leftStart) = try TweakPacked.read(left, at: 0)
            let (rightCount, rightStart) = try TweakPacked.read(right, at: 0)
            if leftCount != rightCount { return leftCount < rightCount ? -1 : 1 }

            var leftCursor = leftStart
            var rightCursor = rightStart
            for _ in 0..<leftCount {
                let (leftValue, nextLeft) = try TweakBlob.readValue(left, at: leftCursor, type: element)
                let (rightValue, nextRight) = try TweakBlob.readValue(right, at: rightCursor, type: element)
                let ordering = try compare(leftValue, rightValue, type: element)
                if ordering != 0 { return ordering }
                leftCursor = nextLeft
                rightCursor = nextRight
            }
            guard leftCursor == left.count, rightCursor == right.count else {
                throw TweakValueOrderError.malformedValue(type)
            }
            return 0
        }
    }

    public static func isSorted(_ values: [Data], type: TweakValueType) throws -> Bool {
        if case .color = type { throw TweakValueOrderError.unsupportedType(.color) }
        guard values.count > 1 else { return true }
        for index in 1..<values.count {
            if try compare(values[index - 1], values[index], type: type) > 0 {
                return false
            }
        }
        return true
    }

    public static func insertionIndex(
        for value: Data,
        in values: [Data],
        type: TweakValueType
    ) throws -> Int {
        if case .color = type { throw TweakValueOrderError.unsupportedType(.color) }
        if case .cname = type {
            let bytes = try content(of: value, type: type)
            guard bytes.allSatisfy({ $0 < 0x80 }) else {
                throw TweakValueOrderError.nonASCIICName(String(decoding: bytes, as: UTF8.self))
            }
        }
        if type != .color, try !isSorted(values, type: type) {
            throw TweakValueOrderError.poolNotSorted(type)
        }

        var low = 0
        var high = values.count
        while low < high {
            let middle = (low + high) / 2
            if try compare(values[middle], value, type: type) < 0 {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    private static func valueUInt32(_ value: Data, at offset: Int = 0, type: TweakValueType) throws -> UInt32 {
        guard offset >= 0, offset <= value.count,
              value.count == (type.fixedWidth ?? 0),
              4 <= value.count - offset else {
            throw TweakValueOrderError.malformedValue(type)
        }
        return try value.uint32LE(at: offset)
    }

    private static func valueUInt64(_ value: Data, type: TweakValueType) throws -> UInt64 {
        guard value.count == 8 else {
            throw TweakValueOrderError.malformedValue(type)
        }
        return try value.uint64LE(at: 0)
    }

    private static func content(of value: Data, type: TweakValueType) throws -> [UInt8] {
        let (length, next) = try TweakPacked.read(value, at: 0)
        guard length >= 0, next <= value.count, length == value.count - next else {
            throw TweakValueOrderError.malformedValue(type)
        }
        return Array(value[next...])
    }

    private static func compareBytes(_ left: [UInt8], _ right: [UInt8]) -> Int {
        if left == right { return 0 }
        return left.lexicographicallyPrecedes(right) ? -1 : 1
    }
}
