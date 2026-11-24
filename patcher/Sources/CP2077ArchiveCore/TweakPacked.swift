import Foundation

public enum TweakPackedError: Error, CustomStringConvertible {
    case truncated(Int)
    case overflow(Int)

    public var description: String {
        switch self {
        case let .truncated(offset):
            return "packed integer at offset \(offset) runs past the end of the blob"
        case let .overflow(offset):
            return "packed integer at offset \(offset) exceeds the supported integer range"
        }
    }
}

/// RedEngine's variable-length integer encoding.
public enum TweakPacked {
    public static func read(_ data: Data, at offset: Int) throws -> (value: Int, next: Int) {
        guard offset >= 0, offset < data.count else {
            throw TweakPackedError.truncated(offset)
        }

        var cursor = offset
        let first = data[cursor]
        cursor += 1

        var value = Int(first & 0x3F)
        var shift = 6
        if first & 0x40 != 0 {
            while true {
                guard cursor < data.count else {
                    throw TweakPackedError.truncated(cursor)
                }
                let byte = data[cursor]
                cursor += 1
                let part = Int(byte & 0x7F)
                guard shift < Int.bitWidth, part <= (Int.max >> shift) else {
                    throw TweakPackedError.overflow(cursor - 1)
                }
                value |= part << shift
                shift += 7
                if byte & 0x80 == 0 {
                    break
                }
            }
        }
        return (value, cursor)
    }

    public static func encode(_ value: Int, wideFlag: Bool = true) -> Data {
        precondition(value >= 0, "packed integers are unsigned in this format")

        var bytes: [UInt8] = []
        var first = UInt8(value & 0x3F)
        if wideFlag {
            first |= 0x80
        }

        var remainder = value >> 6
        if remainder != 0 {
            first |= 0x40
            bytes.append(first)
            while remainder != 0 {
                var byte = UInt8(remainder & 0x7F)
                remainder >>= 7
                if remainder != 0 {
                    byte |= 0x80
                }
                bytes.append(byte)
            }
        } else {
            bytes.append(first)
        }
        return Data(bytes)
    }
}

public enum TweakValueType: Hashable, Sendable {
    case bool, int32, float, string, cname
    case tweakDBID, raRefCResource, locKeyWrapper
    case vector2, vector3, eulerAngles, quaternion, color
    indirect case array(TweakValueType)

    public static let scalars: [TweakValueType] = [
        .bool, .int32, .float, .string, .cname, .tweakDBID,
        .raRefCResource, .locKeyWrapper, .vector2, .vector3,
        .eulerAngles, .quaternion, .color,
    ]

    public var typeName: String {
        switch self {
        case .bool: return "Bool"
        case .int32: return "Int32"
        case .float: return "Float"
        case .string: return "String"
        case .cname: return "CName"
        case .tweakDBID: return "TweakDBID"
        case .raRefCResource: return "raRef:CResource"
        case .locKeyWrapper: return "gamedataLocKeyWrapper"
        case .vector2: return "Vector2"
        case .vector3: return "Vector3"
        case .eulerAngles: return "EulerAngles"
        case .quaternion: return "Quaternion"
        case .color: return "Color"
        case let .array(element): return "array:\(element.typeName)"
        }
    }

    public var fixedWidth: Int? {
        switch self {
        case .bool: return 1
        case .int32, .float: return 4
        case .tweakDBID, .raRefCResource, .locKeyWrapper, .vector2: return 8
        case .vector3, .eulerAngles: return 12
        case .quaternion, .color: return 16
        case .string, .cname, .array: return nil
        }
    }

    public var isStringLike: Bool {
        switch self {
        case .string, .cname: return true
        default: return false
        }
    }

    public var elementType: TweakValueType? {
        if case let .array(element) = self {
            return element
        }
        return nil
    }

    private static let byHash: [UInt64: TweakValueType] = {
        var table: [UInt64: TweakValueType] = [:]
        for scalar in scalars {
            table[Hashes.fnv1a64(scalar.typeName)] = scalar
            let arrayType = TweakValueType.array(scalar)
            table[Hashes.fnv1a64(arrayType.typeName)] = arrayType
        }
        return table
    }()

    public init?(typeNameHash: UInt64) {
        guard let type = Self.byHash[typeNameHash] else {
            return nil
        }
        self = type
    }
}

public extension Hashes {
    /// FNV-1a 64 over raw UTF-8 bytes. Type names are case-sensitive.
    static func fnv1a64(_ string: String) -> UInt64 {
        fnv1a64(Data(string.utf8))
    }

    static func fnv1a64(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
