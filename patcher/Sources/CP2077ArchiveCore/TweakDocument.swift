import Foundation
import Yams

public enum TweakDocumentError: Error, CustomStringConvertible {
    case malformed(URL, String)
    case unsupportedConstruct(URL, String)

    public var description: String {
        switch self {
        case let .malformed(url, detail):
            return "\(url.lastPathComponent): \(detail)"
        case let .unsupportedConstruct(url, detail):
            return "\(url.lastPathComponent): unsupported construct, \(detail)"
        }
    }
}

public enum TweakLiteral: Sendable, Equatable {
    case int(Int32)
    case float(Float)
    case bool(Bool)
    case string(String)
    case cname(String)
    case tweakDBID(String)
    case locKey(UInt64)
    indirect case array([TweakLiteral])
}

public enum TweakBlobSelector: String, Sendable, Equatable {
    case base
    case ep1
}

public enum TweakOperation: Sendable, Equatable {
    case assign(flat: String, selector: TweakBlobSelector?, value: TweakLiteral)
    case arrayAppend(flat: String, selector: TweakBlobSelector?, elements: [TweakLiteral])
    case arrayRemove(flat: String, selector: TweakBlobSelector?, elements: [TweakLiteral])

    public var targetFlat: String {
        switch self {
        case let .assign(flat, _, _), let .arrayAppend(flat, _, _), let .arrayRemove(flat, _, _):
            return flat
        }
    }
}

/// Normalizes the deliberately small existing-flat YAML subset used by the
/// offline TweakDB builder. New records and unknown mappings are rejected so a
/// document cannot be silently interpreted as a different operation.
public enum TweakDocument {
    public static func parse(contentsOf url: URL) throws -> [TweakOperation] {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw TweakDocumentError.malformed(url, "could not read as UTF-8")
        }
        return try parse(text, source: url)
    }

    public static func parse(_ yaml: String, source: URL) throws -> [TweakOperation] {
        let root: Yams.Node
        do {
            guard let composed = try Yams.compose(yaml: yaml) else {
                throw TweakDocumentError.malformed(source, "document is empty")
            }
            root = composed
        } catch let error as TweakDocumentError {
            throw error
        } catch {
            throw TweakDocumentError.malformed(source, String(describing: error))
        }

        guard case let .mapping(mapping) = root else {
            throw TweakDocumentError.malformed(source, "top level must be a mapping of record names")
        }

        let records = mapping.sorted { left, right in
            utf8Precedes(left.key.string ?? "", right.key.string ?? "")
        }
        var operations: [TweakOperation] = []
        for pair in records {
            guard let recordName = pair.key.string, !recordName.isEmpty else {
                throw TweakDocumentError.malformed(source, "record names must be non-empty strings")
            }
            guard case let .mapping(properties) = pair.value else {
                throw TweakDocumentError.malformed(
                    source, "\(recordName) must map property names to values"
                )
            }

            let sortedProperties = properties.sorted { left, right in
                utf8Precedes(left.key.string ?? "", right.key.string ?? "")
            }
            for property in sortedProperties {
                guard let propertyName = property.key.string, !propertyName.isEmpty else {
                    throw TweakDocumentError.malformed(source, "\(recordName) has an invalid property name")
                }
                if propertyName.hasPrefix("$") {
                    throw TweakDocumentError.unsupportedConstruct(
                        source, "\(recordName).\(propertyName) creates or selects a new record"
                    )
                }

                let flat = "\(recordName).\(propertyName)"
                let (selector, selectedValue) = try selectBlob(
                    property.value, flat: flat, source: source
                )
                if let operation = try taggedArrayOperation(
                    selectedValue, flat: flat, selector: selector, source: source
                ) {
                    operations.append(operation)
                } else {
                    operations.append(.assign(
                        flat: flat,
                        selector: selector,
                        value: try literal(selectedValue, source: source, path: flat)
                    ))
                }
            }
        }
        return operations
    }

    private static func taggedArrayOperation(
        _ node: Yams.Node,
        flat: String,
        selector: TweakBlobSelector?,
        source: URL
    ) throws -> TweakOperation? {
        let tag = node.tag.description
        if tag == "!append" || tag == "!remove" {
            guard case .sequence = node else {
                throw TweakDocumentError.malformed(source, "\(flat) \(tag) expects a list")
            }
            let elements = try node.array().map {
                try literal($0, source: source, path: flat)
            }
            return tag == "!append"
                ? .arrayAppend(flat: flat, selector: selector, elements: elements)
                : .arrayRemove(flat: flat, selector: selector, elements: elements)
        }

        guard case let .mapping(mapping) = node else { return nil }
        let pairs = Array(mapping)
        guard pairs.count == 1, let pair = pairs.first, let key = pair.key.string else {
            throw TweakDocumentError.unsupportedConstruct(
                source, "\(flat) uses a mapping that is neither !append nor !remove"
            )
        }
        guard key == "!append" || key == "append" || key == "!remove" || key == "remove" else {
            throw TweakDocumentError.unsupportedConstruct(
                source, "\(flat) uses an unsupported mapping"
            )
        }
        guard case .sequence = pair.value else {
            throw TweakDocumentError.malformed(source, "\(flat) \(key) expects a list")
        }
        let elements = try pair.value.array().map {
            try literal($0, source: source, path: flat)
        }
        if key == "!append" || key == "append" {
            return .arrayAppend(flat: flat, selector: selector, elements: elements)
        }
        return .arrayRemove(flat: flat, selector: selector, elements: elements)
    }

    private static func selectBlob(
        _ node: Yams.Node,
        flat: String,
        source: URL
    ) throws -> (TweakBlobSelector?, Yams.Node) {
        guard case let .mapping(mapping) = node else { return (nil, node) }
        let pairs = Array(mapping)
        guard pairs.count == 1, let pair = pairs.first, let key = pair.key.string else {
            throw TweakDocumentError.unsupportedConstruct(source, "\(flat) uses an unsupported mapping")
        }
        if key == "!append" || key == "append" || key == "!remove" || key == "remove" {
            return (nil, node)
        }
        guard let selector = TweakBlobSelector(rawValue: key) else {
            throw TweakDocumentError.unsupportedConstruct(source, "\(flat) has unknown blob selector \(key)")
        }
        return (selector, pair.value)
    }

    private static func literal(
        _ node: Yams.Node,
        source: URL,
        path: String
    ) throws -> TweakLiteral {
        switch node {
        case let .scalar(scalar):
            switch node.tag.description {
            case "tag:yaml.org,2002:bool":
                guard let value = Bool(scalar.string) else { break }
                return .bool(value)
            case "tag:yaml.org,2002:int":
                guard let value = Int(scalar.string), let narrowed = Int32(exactly: value) else {
                    throw TweakDocumentError.unsupportedConstruct(source, "\(path) does not fit in Int32")
                }
                return .int(narrowed)
            case "tag:yaml.org,2002:float":
                guard let value = Double(scalar.string), value.isFinite else { break }
                let converted = Float(value)
                guard converted.isFinite else { break }
                return .float(converted)
            case "tag:yaml.org,2002:str", "!":
                return .string(scalar.string)
            default:
                break
            }
            throw TweakDocumentError.unsupportedConstruct(
                source, "\(path) has an unsupported scalar type"
            )
        case .sequence:
            return .array(try node.array().map { try literal($0, source: source, path: path) })
        case .mapping:
            throw TweakDocumentError.unsupportedConstruct(source, "\(path) uses a nested mapping")
        }
    }

    private static func utf8Precedes(_ left: String, _ right: String) -> Bool {
        let leftBytes = Array(left.utf8)
        let rightBytes = Array(right.utf8)
        for (leftByte, rightByte) in zip(leftBytes, rightBytes) {
            if leftByte != rightByte { return leftByte < rightByte }
        }
        return leftBytes.count < rightBytes.count
    }
}
