import Foundation

public enum RDARWriterError: Error, CustomStringConvertible {
    case invalidSegmentRange(UInt64, URL)
    case valueTooLarge(String)

    public var description: String {
        switch self {
        case let .invalidSegmentRange(hash, url):
            return "record \(Hashes.hex64(hash)) in \(url.lastPathComponent) has a segment range outside the segment table"
        case let .valueTooLarge(name):
            return "RDAR \(name) exceeds the format's 32-bit limit"
        }
    }
}

/// Emits a fresh RDAR archive from parsed source records.
///
/// Payload segments and source-owned record bytes are copied verbatim. Only the
/// segment and dependency ranges are changed because those refer to tables that
/// are rebuilt for the output archive.
public enum RDARWriter {
    /// Re-emits every record in an archive. This is primarily useful for proving
    /// that the writer preserves an existing archive's parsed semantics.
    @discardableResult
    public static func write(archive: RDARArchive, to destination: URL) throws -> URL {
        let records = try archive.records.map {
            WriteRecord(source: archive, record: $0, dependencies: try archive.dependencies(for: $0))
        }
        return try write(records: records, headerTemplate: archive, to: destination)
    }

    /// Emits the winning records selected by a patch plan.
    @discardableResult
    public static func write(
        winners: [WinningRecord],
        headerTemplate: RDARArchive,
        to destination: URL
    ) throws -> URL {
        var sourceCache: [URL: RDARArchive] = [:]
        let records = try winners.map { winner -> WriteRecord in
            let source: RDARArchive
            if let cached = sourceCache[winner.modArchive] {
                source = cached
            } else {
                source = try RDARArchive.read(winner.modArchive)
                sourceCache[winner.modArchive] = source
            }
            return WriteRecord(source: source, record: winner.record, dependencies: winner.dependencies)
        }
        return try write(records: records, headerTemplate: headerTemplate, to: destination)
    }

    private static func write(
        records: [WriteRecord],
        headerTemplate: RDARArchive,
        to destination: URL
    ) throws -> URL {
        let ordered = records.enumerated().sorted { lhs, rhs in
            if lhs.element.record.nameHash != rhs.element.record.nameHash {
                return lhs.element.record.nameHash < rhs.element.record.nameHash
            }
            return lhs.offset < rhs.offset
        }.map(\.element)

        var segmentCount = 0
        var dependencyCount = 0
        for item in ordered {
            let start = Int(item.record.segmentsStart)
            let end = Int(item.record.segmentsEnd)
            guard start <= end, end <= item.source.segments.count else {
                throw RDARWriterError.invalidSegmentRange(item.record.nameHash, item.source.url)
            }
            segmentCount += end - start
            dependencyCount += item.dependencies.count
        }

        guard let recordCount32 = UInt32(exactly: ordered.count) else {
            throw RDARWriterError.valueTooLarge("record count")
        }
        guard let segmentCount32 = UInt32(exactly: segmentCount) else {
            throw RDARWriterError.valueTooLarge("segment count")
        }
        guard let dependencyCount32 = UInt32(exactly: dependencyCount) else {
            throw RDARWriterError.valueTooLarge("dependency count")
        }

        let indexByteCount = 28 + ordered.count * 56 + segmentCount * 16 + dependencyCount * 8
        guard let indexSize32 = UInt32(exactly: indexByteCount) else {
            throw RDARWriterError.valueTooLarge("index size")
        }

        let manager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var keepTemporary = true
        defer {
            if keepTemporary { try? manager.removeItem(at: temporary) }
        }

        let output = try FileHandle(forWritingTo: temporary)
        var outputClosed = false
        var sourceHandles: [URL: FileHandle] = [:]
        defer {
            if !outputClosed { try? output.close() }
            for handle in sourceHandles.values { try? handle.close() }
        }
        func sourceHandle(_ url: URL) throws -> FileHandle {
            if let handle = sourceHandles[url] { return handle }
            let handle = try FileHandle(forReadingFrom: url)
            sourceHandles[url] = handle
            return handle
        }

        // Reserve the template header, then stream payloads in record order.
        try output.write(contentsOf: headerTemplate.header)
        var payloadOffset: UInt64 = UInt64(headerTemplate.header.count)
        var segmentEntries: [(offset: UInt64, compressedSize: UInt32, size: UInt32)] = []
        var ranges: [(segments: Range<UInt32>, dependencies: Range<UInt32>)] = []
        segmentEntries.reserveCapacity(segmentCount)
        ranges.reserveCapacity(ordered.count)
        var nextSegment: UInt32 = 0
        var nextDependency: UInt32 = 0

        for item in ordered {
            let segmentStart = nextSegment
            let handle = try sourceHandle(item.source.url)
            for index in Int(item.record.segmentsStart)..<Int(item.record.segmentsEnd) {
                let segment = item.source.segments[index]
                try handle.seek(toOffset: segment.offset)
                let payload = try handle.read(upToCount: Int(segment.compressedSize)) ?? Data()
                guard payload.count == Int(segment.compressedSize) else {
                    throw BinaryError.shortRead(item.source.url, Int(segment.compressedSize))
                }
                try output.write(contentsOf: payload)
                segmentEntries.append((payloadOffset, segment.compressedSize, segment.size))
                payloadOffset += UInt64(segment.compressedSize)
                nextSegment += 1
            }

            let dependencyStart = nextDependency
            nextDependency += UInt32(item.dependencies.count)
            ranges.append((segmentStart..<nextSegment, dependencyStart..<nextDependency))
        }

        let indexPosition = alignUp(payloadOffset, to: 4096)
        if indexPosition > payloadOffset {
            try output.write(contentsOf: Data(count: Int(indexPosition - payloadOffset)))
        }

        var index = Data(count: indexByteCount)
        try index.writeUInt32LE(8, at: 0)
        try index.writeUInt32LE(indexSize32 - 8, at: 4)
        try index.writeUInt32LE(recordCount32, at: 16)
        try index.writeUInt32LE(segmentCount32, at: 20)
        try index.writeUInt32LE(dependencyCount32, at: 24)

        let recordsOffset = 28
        let segmentsOffset = recordsOffset + ordered.count * 56
        let dependenciesOffset = segmentsOffset + segmentEntries.count * 16
        var dependencyIndex = 0

        for (position, item) in ordered.enumerated() {
            let recordOffset = recordsOffset + position * 56
            index.replaceSubrange(recordOffset..<recordOffset + 56, with: item.record.bytes)
            try index.writeUInt32LE(ranges[position].segments.lowerBound, at: recordOffset + 20)
            try index.writeUInt32LE(ranges[position].segments.upperBound, at: recordOffset + 24)
            try index.writeUInt32LE(ranges[position].dependencies.lowerBound, at: recordOffset + 28)
            try index.writeUInt32LE(ranges[position].dependencies.upperBound, at: recordOffset + 32)

            for dependency in item.dependencies {
                try index.writeUInt64LE(dependency, at: dependenciesOffset + dependencyIndex * 8)
                dependencyIndex += 1
            }
        }

        for (position, segment) in segmentEntries.enumerated() {
            let segmentOffset = segmentsOffset + position * 16
            try index.writeUInt64LE(segment.offset, at: segmentOffset)
            try index.writeUInt32LE(segment.compressedSize, at: segmentOffset + 8)
            try index.writeUInt32LE(segment.size, at: segmentOffset + 12)
        }
        try index.writeUInt64LE(Hashes.crc64(index.subdata(in: 16..<index.count)), at: 8)
        try output.write(contentsOf: index)

        let indexEnd = indexPosition + UInt64(index.count)
        let fileSize = alignUp(indexEnd, to: 4096)
        if fileSize > indexEnd {
            try output.write(contentsOf: Data(count: Int(fileSize - indexEnd)))
        }

        var header = headerTemplate.header
        try header.writeUInt64LE(indexPosition, at: 8)
        try header.writeUInt32LE(indexSize32, at: 16)
        try header.writeUInt64LE(fileSize, at: 32)
        try output.seek(toOffset: 0)
        try output.write(contentsOf: header)
        try output.close()
        outputClosed = true

        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try manager.moveItem(at: temporary, to: destination)
        }
        keepTemporary = false
        return destination.normalizedFileURL
    }
}

private struct WriteRecord {
    let source: RDARArchive
    let record: RDARRecord
    let dependencies: [UInt64]
}
