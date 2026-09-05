import CP2077ArchiveCore
import Foundation

/// A record to synthesise into a test archive.
///
/// `payloads` is one entry per segment, so a record with two payloads produces a
/// two-segment record. Every other field maps directly onto the 56-byte on-disk
/// record so tests can assert that a transplant carried it across.
struct TestRecord {
    let hash: UInt64
    var payloads: [Data]
    var timestamp: UInt64 = 0
    var inlineBufferSegments: UInt32 = 0
    var sha1Fill: UInt8 = 0
    var dependencies: [UInt64] = []

    init(
        hash: UInt64,
        payload: Data,
        timestamp: UInt64 = 0,
        inlineBufferSegments: UInt32 = 0,
        sha1Fill: UInt8 = 0,
        dependencies: [UInt64] = []
    ) {
        self.init(
            hash: hash,
            payloads: [payload],
            timestamp: timestamp,
            inlineBufferSegments: inlineBufferSegments,
            sha1Fill: sha1Fill,
            dependencies: dependencies
        )
    }

    init(
        hash: UInt64,
        payloads: [Data],
        timestamp: UInt64 = 0,
        inlineBufferSegments: UInt32 = 0,
        sha1Fill: UInt8 = 0,
        dependencies: [UInt64] = []
    ) {
        self.hash = hash
        self.payloads = payloads
        self.timestamp = timestamp
        self.inlineBufferSegments = inlineBufferSegments
        self.sha1Fill = sha1Fill
        self.dependencies = dependencies
    }
}

enum TestArchiveError: Error {
    case shortRead(URL, Int)
}

/// Writes a minimal but structurally valid RDAR archive.
///
/// Segments are laid out in record order starting after the 52-byte header, the
/// index is 4096-aligned, and each record owns a contiguous unshared slice of the
/// dependency table — matching the layout measured across the shipped archives.
func writeTestArchive(to url: URL, records: [TestRecord]) throws {
    var body = Data(count: 52)
    var segmentPlacements: [[(offset: UInt64, size: Int)]] = []
    for record in records {
        var placements: [(offset: UInt64, size: Int)] = []
        for payload in record.payloads {
            placements.append((UInt64(body.count), payload.count))
            body.append(payload)
        }
        segmentPlacements.append(placements)
    }

    let indexPosition = alignUpForTest(UInt64(body.count), to: 4096)
    body.append(Data(count: Int(indexPosition) - body.count))

    let segmentCount = segmentPlacements.reduce(0) { $0 + $1.count }
    let dependencies = records.flatMap(\.dependencies)

    var index = Data(count: 28 + records.count * 56 + segmentCount * 16 + dependencies.count * 8)
    try index.writeUInt32LEForTest(UInt32(index.count - 8), at: 4)
    try index.writeUInt32LEForTest(UInt32(records.count), at: 16)
    try index.writeUInt32LEForTest(UInt32(segmentCount), at: 20)
    try index.writeUInt32LEForTest(UInt32(dependencies.count), at: 24)

    let recordsOffset = 28
    let segmentsOffset = recordsOffset + records.count * 56
    let dependenciesOffset = segmentsOffset + segmentCount * 16

    var nextSegment = 0
    var nextDependency = 0
    for (i, record) in records.enumerated() {
        let recordOffset = recordsOffset + i * 56
        let placements = segmentPlacements[i]

        try index.writeUInt64LEForTest(record.hash, at: recordOffset)
        try index.writeUInt64LEForTest(record.timestamp, at: recordOffset + 8)
        try index.writeUInt32LEForTest(record.inlineBufferSegments, at: recordOffset + 16)
        try index.writeUInt32LEForTest(UInt32(nextSegment), at: recordOffset + 20)
        try index.writeUInt32LEForTest(UInt32(nextSegment + placements.count), at: recordOffset + 24)
        try index.writeUInt32LEForTest(UInt32(nextDependency), at: recordOffset + 28)
        try index.writeUInt32LEForTest(UInt32(nextDependency + record.dependencies.count), at: recordOffset + 32)
        index.replaceSubrange(recordOffset + 36..<recordOffset + 56, with: Data(repeating: record.sha1Fill, count: 20))

        for placement in placements {
            let segmentOffset = segmentsOffset + nextSegment * 16
            try index.writeUInt64LEForTest(placement.offset, at: segmentOffset)
            try index.writeUInt32LEForTest(UInt32(placement.size), at: segmentOffset + 8)
            try index.writeUInt32LEForTest(UInt32(placement.size), at: segmentOffset + 12)
            nextSegment += 1
        }

        for dependency in record.dependencies {
            try index.writeUInt64LEForTest(dependency, at: dependenciesOffset + nextDependency * 8)
            nextDependency += 1
        }
    }
    try index.writeUInt64LEForTest(Hashes.crc64(index.subdata(in: 16..<index.count)), at: 8)

    body.append(index)
    let fileSize = alignUpForTest(UInt64(body.count), to: 4096)
    body.append(Data(count: Int(fileSize) - body.count))

    body.replaceSubrange(0..<4, with: Data("RDAR".utf8))
    try body.writeUInt64LEForTest(indexPosition, at: 8)
    try body.writeUInt32LEForTest(UInt32(index.count), at: 16)
    try body.writeUInt64LEForTest(fileSize, at: 32)

    try body.write(to: url)
}

func compressedRecordData(_ record: RDARRecord, in archive: RDARArchive) throws -> Data {
    let handle = try FileHandle(forReadingFrom: archive.url)
    defer { try? handle.close() }

    var data = Data()
    for i in 0..<record.segmentCount {
        let segment = archive.segments[Int(record.segmentsStart) + i]
        try handle.seek(toOffset: segment.offset)
        let chunk = try handle.read(upToCount: Int(segment.compressedSize)) ?? Data()
        guard chunk.count == Int(segment.compressedSize) else {
            throw TestArchiveError.shortRead(archive.url, Int(segment.compressedSize))
        }
        data.append(chunk)
    }
    return data
}

/// A scratch directory containing a game root with `archive/Mac/{content,ep1}`.
struct TestGame {
    let root: URL
    let gameRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "cp2077-patcher-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        gameRoot = root.appending(path: "Game", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contentDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ep1Directory, withIntermediateDirectories: true)
    }

    var contentDirectory: URL {
        gameRoot.appending(path: "archive/Mac/content", directoryHint: .isDirectory)
    }

    var ep1Directory: URL {
        gameRoot.appending(path: "archive/Mac/ep1", directoryHint: .isDirectory)
    }

    var install: GameInstall {
        GameInstall(root: gameRoot)
    }

    /// Writes an official archive into `archive/Mac/content`.
    @discardableResult
    func writeOfficial(_ name: String, records: [TestRecord]) throws -> URL {
        let url = contentDirectory.appending(path: name)
        try writeTestArchive(to: url, records: records)
        return url
    }

    /// Writes a mod archive outside the game tree.
    @discardableResult
    func writeMod(_ name: String, records: [TestRecord]) throws -> URL {
        let url = root.appending(path: name)
        try writeTestArchive(to: url, records: records)
        return url
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

func alignUpForTest(_ value: UInt64, to alignment: UInt64) -> UInt64 {
    ((value + alignment - 1) / alignment) * alignment
}

extension Data {
    mutating func writeUInt32LEForTest(_ value: UInt32, at offset: Int) throws {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { bytes in
            replaceSubrange(offset..<offset + 4, with: bytes)
        }
    }

    mutating func writeUInt64LEForTest(_ value: UInt64, at offset: Int) throws {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { bytes in
            replaceSubrange(offset..<offset + 8, with: bytes)
        }
    }
}
