import CP2077ArchiveCore
import Foundation
import Testing

/// Locates the vanilla archives in `pristine/`, when the checkout has them.
///
/// Every other fixture in this suite is synthesised by `TestArchiveBuilder`,
/// which lays an index out using the same model `RDARArchive.read` assumes. That
/// circularity means the whole suite would still pass if the model were wrong
/// about real archives. These tests are the only ones that break it.
///
/// `pristine/` is gitignored — it is copyrighted game data and must never be
/// committed — so these tests skip on a checkout that has not been populated.
enum RealArchives {
    static let directories: [URL] = {
        // .../patcher/Tests/CP2077ArchiveCoreTests/<this file>
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return [root.appending(path: "pristine/content"), root.appending(path: "pristine/ep1")]
    }()

    static let urls: [URL] = {
        directories.flatMap { dir -> [URL] in
            let found = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )
            return (found ?? []).filter { $0.pathExtension == "archive" }
        }.sorted { $0.path < $1.path }
    }()

    static var available: Bool { !urls.isEmpty }
}

@Test(.enabled(if: RealArchives.available))
func realArchivesPutTheDependencyTableLastInTheIndex() throws {
    for url in RealArchives.urls {
        let archive = try RDARArchive.read(url)
        let name = url.lastPathComponent

        #expect(
            archive.dependenciesOffset + Int(archive.dependencyCount) * 8 == archive.indexData.count,
            "\(name): dependency table is not last in the index"
        )
        // Appending depends on this: a record range may never point past the table.
        #expect(
            archive.records.map(\.dependenciesEnd).max() ?? 0 == archive.dependencyCount,
            "\(name): max(dependenciesEnd) != dependencyCount"
        )
        // The header arithmetic in Patcher assumes this encoding of offset 4.
        let sizeField = archive.indexData[4..<8].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        #expect(
            sizeField == UInt32(archive.indexData.count - 8),
            "\(name): index size field is not indexSize - 8"
        )
    }
}

@Test(.enabled(if: RealArchives.available))
func realArchiveRecordsOwnContiguousUnsharedDependencySlices() throws {
    for url in RealArchives.urls {
        let archive = try RDARArchive.read(url)
        let name = url.lastPathComponent

        let spans = archive.records
            .filter { $0.dependenciesEnd > $0.dependenciesStart }
            .map { (start: Int($0.dependenciesStart), end: Int($0.dependenciesEnd)) }
            .sorted { $0.start < $1.start }

        // Appending to the table only leaves existing ranges valid because the
        // slices tile the table exactly: no record shares a slice with another,
        // and none straddles a neighbour.
        var cursor = 0
        for span in spans {
            #expect(span.start == cursor, "\(name): dependency slices are not contiguous at \(span.start)")
            cursor = span.end
        }
        #expect(cursor == Int(archive.dependencyCount), "\(name): dependency slices do not fill the table")
    }
}

@Test(.enabled(if: RealArchives.available))
func realArchiveIndexSurvivesAByteIdenticalRoundTrip() throws {
    for url in RealArchives.urls {
        let archive = try RDARArchive.read(url)
        let name = url.lastPathComponent

        var rebuilt = Data()
        rebuilt.reserveCapacity(archive.indexData.count - archive.recordsOffset)
        for record in archive.records {
            rebuilt.append(record.bytes)
        }
        for segment in archive.segments {
            var chunk = Data(count: 16)
            try chunk.writeUInt64LEForTest(segment.offset, at: 0)
            try chunk.writeUInt32LEForTest(segment.compressedSize, at: 8)
            try chunk.writeUInt32LEForTest(segment.size, at: 12)
            rebuilt.append(chunk)
        }
        for dependency in archive.dependencies {
            var chunk = Data(count: 8)
            try chunk.writeUInt64LEForTest(dependency, at: 0)
            rebuilt.append(chunk)
        }

        // Every byte after the 28-byte header is accounted for by the parsed
        // structures, so nothing in a real index is being silently dropped.
        #expect(
            rebuilt == archive.indexData[archive.recordsOffset...],
            "\(name): re-serialised index does not match the bytes on disk"
        )
    }
}

@Test(.enabled(if: RealArchives.available))
func realArchiveRecordTablesAreSortedByNameHash() throws {
    for url in RealArchives.urls {
        let archive = try RDARArchive.read(url)
        let hashes = archive.records.map(\.nameHash)
        // Patching re-sorts the record table by hash. That is only
        // order-preserving because the shipped tables are already in this order.
        #expect(hashes == hashes.sorted(), "\(url.lastPathComponent): record table is not sorted by nameHash")
    }
}
