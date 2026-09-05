import Foundation

public enum RDARArchiveError: Error, CustomStringConvertible {
    case notRDAR(URL)
    case unsupportedDependencyInsert(String)
    case duplicatePatch(UInt64)
    case ambiguousTargetRecord(UInt64, URL)
    case noTargetArchive(URL)
    case dependencyRangeOutOfBounds(UInt64, URL)

    public var description: String {
        switch self {
        case let .notRDAR(url):
            return "\(url.path) is not an RDAR archive"
        case let .unsupportedDependencyInsert(label):
            return "cannot insert \(label): source record has dependencies"
        case let .duplicatePatch(hash):
            return "duplicate patch requested for \(Hashes.hex64(hash))"
        case let .ambiguousTargetRecord(hash, url):
            return "target archive \(url.lastPathComponent) has non-identical duplicate records for \(Hashes.hex64(hash)); refusing ambiguous replacement"
        case let .noTargetArchive(url):
            return "could not choose a target Mac archive for \(url.lastPathComponent); pass --target"
        case let .dependencyRangeOutOfBounds(hash, url):
            return "record \(Hashes.hex64(hash)) in \(url.lastPathComponent) has a dependency range outside the dependency table"
        }
    }
}

public struct RDARRecord: Sendable {
    public let index: Int
    public let offset: Int
    public let nameHash: UInt64
    public let bytes: Data
    public let timestamp: UInt64
    public let numInlineBufferSegments: UInt32
    public let segmentsStart: UInt32
    public let segmentsEnd: UInt32
    public let dependenciesStart: UInt32
    public let dependenciesEnd: UInt32
    public let sha1: Data

    public var segmentCount: Int {
        Int(segmentsEnd - segmentsStart)
    }
}

public struct RDARSegment: Sendable {
    public let index: Int
    public let offset: UInt64
    public let compressedSize: UInt32
    public let size: UInt32
}

public struct RDARArchive: Sendable {
    public let url: URL
    public let header: Data
    public let indexPosition: UInt64
    public let indexSize: UInt32
    public let fileSize: UInt64
    public let indexData: Data
    public let fileEntryCount: UInt32
    public let fileSegmentCount: UInt32
    public let dependencyCount: UInt32
    public let recordsOffset: Int
    public let segmentsOffset: Int
    public let dependenciesOffset: Int
    public let records: [RDARRecord]
    public let segments: [RDARSegment]
    /// The dependency table parsed as resource hashes. The table is last in the
    /// index and each record owns a contiguous, unshared slice of it.
    public let dependencies: [UInt64]

    public static func read(_ url: URL) throws -> RDARArchive {
        let header = try readData(url: url, offset: 0, count: 52)
        guard String(data: header[0..<4], encoding: .ascii) == "RDAR" else {
            throw RDARArchiveError.notRDAR(url)
        }

        let indexPosition = try header.uint64LE(at: 8)
        let indexSize = try header.uint32LE(at: 16)
        let fileSize = try header.uint64LE(at: 32)
        let indexData = try readData(url: url, offset: indexPosition, count: Int(indexSize))
        let fileEntryCount = try indexData.uint32LE(at: 16)
        let fileSegmentCount = try indexData.uint32LE(at: 20)
        let dependencyCount = try indexData.uint32LE(at: 24)
        let recordsOffset = 28
        let segmentsOffset = recordsOffset + Int(fileEntryCount) * 56
        let dependenciesOffset = segmentsOffset + Int(fileSegmentCount) * 16

        var records: [RDARRecord] = []
        records.reserveCapacity(Int(fileEntryCount))
        for i in 0..<Int(fileEntryCount) {
            let offset = recordsOffset + i * 56
            let bytes = indexData[offset..<offset + 56]
            records.append(RDARRecord(
                index: i,
                offset: offset,
                nameHash: try indexData.uint64LE(at: offset),
                bytes: Data(bytes),
                timestamp: try indexData.uint64LE(at: offset + 8),
                numInlineBufferSegments: try indexData.uint32LE(at: offset + 16),
                segmentsStart: try indexData.uint32LE(at: offset + 20),
                segmentsEnd: try indexData.uint32LE(at: offset + 24),
                dependenciesStart: try indexData.uint32LE(at: offset + 28),
                dependenciesEnd: try indexData.uint32LE(at: offset + 32),
                sha1: Data(indexData[offset + 36..<offset + 56])
            ))
        }

        var segments: [RDARSegment] = []
        segments.reserveCapacity(Int(fileSegmentCount))
        for i in 0..<Int(fileSegmentCount) {
            let offset = segmentsOffset + i * 16
            segments.append(RDARSegment(
                index: i,
                offset: try indexData.uint64LE(at: offset),
                compressedSize: try indexData.uint32LE(at: offset + 8),
                size: try indexData.uint32LE(at: offset + 12)
            ))
        }

        var dependencies: [UInt64] = []
        dependencies.reserveCapacity(Int(dependencyCount))
        for i in 0..<Int(dependencyCount) {
            dependencies.append(try indexData.uint64LE(at: dependenciesOffset + i * 8))
        }

        return RDARArchive(
            url: url,
            header: header,
            indexPosition: indexPosition,
            indexSize: indexSize,
            fileSize: fileSize,
            indexData: indexData,
            fileEntryCount: fileEntryCount,
            fileSegmentCount: fileSegmentCount,
            dependencyCount: dependencyCount,
            recordsOffset: recordsOffset,
            segmentsOffset: segmentsOffset,
            dependenciesOffset: dependenciesOffset,
            records: records,
            segments: segments,
            dependencies: dependencies
        )
    }

    public var storedCRC: UInt64 {
        (try? indexData.uint64LE(at: 8)) ?? 0
    }

    public var computedCRC: UInt64 {
        Hashes.crc64(indexData.subdata(in: 16..<indexData.count))
    }

    public func record(hash: UInt64) -> RDARRecord? {
        records.first { $0.nameHash == hash }
    }

    /// The dependency hashes a record declares, in table order.
    public func dependencies(for record: RDARRecord) throws -> [UInt64] {
        let start = Int(record.dependenciesStart)
        let end = Int(record.dependenciesEnd)
        guard start <= end, end <= dependencies.count else {
            throw RDARArchiveError.dependencyRangeOutOfBounds(record.nameHash, url)
        }
        return Array(dependencies[start..<end])
    }
}
