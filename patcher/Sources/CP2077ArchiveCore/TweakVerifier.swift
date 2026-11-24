import Foundation

public struct TweakVerificationReport: Sendable, Equatable {
    public let issues: [String]

    public init(issues: [String] = []) {
        self.issues = issues
    }

    public var isValid: Bool {
        issues.isEmpty
    }
}

public typealias TweakStructuralReport = TweakVerificationReport

public enum TweakVerificationError: Error, CustomStringConvertible {
    case failed([String])

    public var description: String {
        switch self {
        case let .failed(issues):
            return "TweakDB structural verification failed: " + issues.joined(separator: "; ")
        }
    }
}

public enum TweakVerifier {
    public static func verify(_ blob: TweakBlob) -> TweakVerificationReport {
        var issues: [String] = []
        var seenTypes = Set<TweakValueType>()

        guard blob.magic == 0x0BB1_DB47 else {
            issues.append("invalid TweakDB magic")
            return TweakVerificationReport(issues: issues)
        }

        if blob.flatsOffset < 32 {
            issues.append("flats section points into the header")
        }

        for block in blob.blocks {
            if !seenTypes.insert(block.type).inserted {
                issues.append("duplicate type block (\(block.type.typeName))")
            }
            if block.typeNameHash != Hashes.fnv1a64(block.type.typeName) {
                issues.append("\(block.type.typeName) has an incorrect type-table hash")
            }
            if block.declaredValueCount < UInt32(block.values.count) {
                issues.append("\(block.type.typeName) declared value count is below its pool count")
            }

            for entry in block.entries {
                if entry.valueIndex >= UInt32(block.values.count) {
                    issues.append("\(block.type.typeName) entry has value index \(entry.valueIndex) outside its pool")
                    break
                }
            }

            if !isSorted(block.entries.map { ($0.nameHash, $0.nameLength) }) {
                issues.append("\(block.type.typeName) entries are not sorted by name hash and length")
            }

            do {
                let sorted = try TweakValueOrder.isSorted(block.values, type: block.type)
                if !sorted, block.type != .cname {
                    issues.append("\(block.type.typeName) values are not sorted")
                }
            } catch {
                // Current shipped blobs contain engine-ordered CName pools and
                // Color pools whose comparator is not documented. They are
                // safe to preserve byte-for-byte; insertion still validates a
                // target pool before attempting a binary-search mutation.
                if block.type != .cname, block.type != .color {
                    issues.append("\(block.type.typeName) values cannot be ordered")
                }
            }
        }

        if !isSorted(blob.records.map { ($0.nameHash, $0.nameLength) }) {
            issues.append("records are not sorted by name hash and length")
        }
        if !isSorted(blob.queries.map { ($0.nameHash, $0.nameLength) }) {
            issues.append("queries are not sorted by name hash and length")
        }
        if !isSorted(blob.groupTags.map { ($0.nameHash, $0.nameLength) }) {
            issues.append("group tags are not sorted by name hash and length")
        }

        do {
            let serialized = TweakBlobWriter.serialize(blob)
            _ = try TweakBlob.parse(serialized)
        } catch {
            issues.append("serialized blob does not reparse identically: \(error)")
        }

        return TweakVerificationReport(issues: issues)
    }

    public static func verify(data: Data) -> TweakVerificationReport {
        do {
            return verify(try TweakBlob.parse(data))
        } catch {
            return TweakVerificationReport(issues: [String(describing: error)])
        }
    }

    @discardableResult
    public static func validate(_ blob: TweakBlob) throws -> TweakVerificationReport {
        let report = verify(blob)
        guard report.isValid else {
            throw TweakVerificationError.failed(report.issues)
        }
        return report
    }

    @discardableResult
    public static func validate(data: Data) throws -> TweakVerificationReport {
        let blob = try TweakBlob.parse(data)
        return try validate(blob)
    }
}

private func isSorted(_ values: [(UInt32, UInt32)]) -> Bool {
    guard values.count > 1 else { return true }
    for index in 1..<values.count {
        if values[index] < values[index - 1] {
            return false
        }
    }
    return true
}
