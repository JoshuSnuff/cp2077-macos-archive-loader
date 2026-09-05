import Foundation

public struct PatchSummary: Sendable {
    public let backupDirectory: URL
    public let patchedCount: Int
    public let insertedCount: Int
    public let replacedCount: Int
    public let targetArchive: URL
}

/// What one run of a plan did to one official archive.
public struct ArchivePatchSummary: Sendable {
    public let targetArchive: URL
    public let backupDirectory: URL
    public let patchedCount: Int
    public let insertedCount: Int
    public let replacedCount: Int
}

/// What one run of a plan did to the install.
public struct PlanPatchSummary: Sendable {
    public let archives: [ArchivePatchSummary]
    public let looseArchive: URL?
    public let newResourceCount: Int
    public let losers: [LosingRecord]

    public var overrideRecordCount: Int {
        archives.reduce(0) { $0 + $1.patchedCount }
    }
}

public struct HybridPatchSummary: Sendable {
    public let sourceArchive: URL
    public let officialPatches: [PatchSummary]
    public let looseArchive: URL?
    public let missingRecordCount: Int

    public var patchedExistingRecordCount: Int {
        officialPatches.reduce(0) { $0 + $1.patchedCount }
    }
}

public enum PatchStrategyKind: String, Sendable {
    case plugin
    case hybrid
    case officialOverride
    case aggressive
}

public struct HybridPatchPlan: Sendable {
    public let sourceArchive: URL
    public let totalRecordCount: Int
    public let existingRecordCount: Int
    public let missingRecordCount: Int
    public let affectedOfficialArchives: [URL]

    public var strategyKind: PatchStrategyKind {
        if existingRecordCount == 0 { return .plugin }
        if missingRecordCount == 0 { return .officialOverride }
        return .hybrid
    }
}

public struct RDARPatcher: Sendable {
    public let game: GameInstall

    public init(game: GameInstall) {
        self.game = game
    }

    // MARK: - Plan-driven patching

    /// Applies a plan to the install.
    ///
    /// Work is grouped by target archive, so each official archive is backed up
    /// and rewritten exactly once per run no matter how many mods contribute
    /// records to it. Patching per mod is what produced hundreds of backup
    /// directories for a single 33-mod injection.
    public func apply(plan: PatchPlan) throws -> PlanPatchSummary {
        var sourceCache: [URL: RDARArchive] = [:]
        func source(_ url: URL) throws -> RDARArchive {
            if let cached = sourceCache[url] { return cached }
            let archive = try RDARArchive.read(url)
            sourceCache[url] = archive
            return archive
        }

        var archives: [ArchivePatchSummary] = []
        for targetURL in plan.targets {
            let hashes = plan.officialWork[targetURL] ?? []
            let writes = try hashes.map { hash -> PlannedWrite in
                guard let winner = plan.winners[hash] else {
                    throw RDARArchiveError.planMissingWinner(hash)
                }
                return PlannedWrite(
                    hash: hash,
                    source: try source(winner.modArchive),
                    record: winner.record,
                    dependencies: winner.dependencies
                )
            }
            archives.append(try patch(targetURL: targetURL, writes: writes))
        }

        let looseArchive = try writeLooseArchive(plan: plan, source: source)

        return PlanPatchSummary(
            archives: archives,
            looseArchive: looseArchive,
            newResourceCount: plan.newResources.count,
            losers: plan.losers
        )
    }

    // MARK: - Single-source entry points

    public func patchAll(sourceArchive sourceURL: URL, targetArchive targetURL: URL) throws -> PatchSummary {
        let source = try RDARArchive.read(sourceURL)
        return try patchSummary(targetURL: targetURL, writes: try source.records.map {
            try PlannedWrite(hash: $0.nameHash, source: source, record: $0, dependencies: source.dependencies(for: $0))
        })
    }

    public func patchPaths(sourceArchive sourceURL: URL, targetArchive targetURL: URL, paths: [String]) throws -> PatchSummary {
        let source = try RDARArchive.read(sourceURL)
        return try patchSummary(targetURL: targetURL, writes: try paths.map { path in
            let hash = Hashes.fnv1a64Path(path)
            guard let record = source.record(hash: hash) else {
                throw RDARArchiveError.noTargetArchive(sourceURL)
            }
            return PlannedWrite(hash: hash, source: source, record: record, dependencies: try source.dependencies(for: record))
        })
    }

    public func patchHashes(sourceArchive sourceURL: URL, targetArchive targetURL: URL, hashes: [UInt64]) throws -> PatchSummary {
        let source = try RDARArchive.read(sourceURL)
        return try patchSummary(targetURL: targetURL, writes: try hashes.map { hash in
            guard let record = source.record(hash: hash) else {
                throw RDARArchiveError.noTargetArchive(sourceURL)
            }
            return PlannedWrite(hash: hash, source: source, record: record, dependencies: try source.dependencies(for: record))
        })
    }

    public func patchHybrid(sourceArchive sourceURL: URL) throws -> HybridPatchSummary {
        let plan = try PatchPlanner.plan(mods: [sourceURL], game: game)
        let summary = try apply(plan: plan)
        return HybridPatchSummary(
            sourceArchive: sourceURL,
            officialPatches: summary.archives.map {
                PatchSummary(
                    backupDirectory: $0.backupDirectory,
                    patchedCount: $0.patchedCount,
                    insertedCount: $0.insertedCount,
                    replacedCount: $0.replacedCount,
                    targetArchive: $0.targetArchive
                )
            },
            looseArchive: summary.looseArchive,
            missingRecordCount: summary.newResourceCount
        )
    }

    public func planHybrid(sourceArchive sourceURL: URL) throws -> HybridPatchPlan {
        let source = try RDARArchive.read(sourceURL)
        let plan = try PatchPlanner.plan(mods: [sourceURL], game: game)
        return HybridPatchPlan(
            sourceArchive: sourceURL,
            totalRecordCount: source.records.count,
            existingRecordCount: plan.overrideCount,
            missingRecordCount: plan.newResources.count,
            affectedOfficialArchives: plan.targets
        )
    }

    public func chooseTarget(sourceArchive: URL, explicitTarget: URL?) throws -> URL {
        if let explicitTarget { return explicitTarget }
        let source = try RDARArchive.read(sourceArchive)
        let sourceHashes = Set(source.records.map(\.nameHash))
        var best: (url: URL, count: Int)?
        for archiveURL in try game.officialMacArchives() {
            let archive = try RDARArchive.read(archiveURL)
            let count = archive.records.filter { sourceHashes.contains($0.nameHash) }.count
            if count > (best?.count ?? 0) {
                best = (archiveURL, count)
            }
        }
        guard let best, best.count > 0 else {
            throw RDARArchiveError.noTargetArchive(sourceArchive)
        }
        return best.url
    }

    private func writeLooseArchive(
        plan: PatchPlan,
        source: (URL) throws -> RDARArchive
    ) throws -> URL? {
        guard !plan.newResources.isEmpty else { return nil }

        var winners: [WinningRecord] = []
        var contributions: [URL: Int] = [:]
        for hash in plan.newResources {
            guard let winner = plan.winners[hash] else {
                throw RDARArchiveError.planMissingWinner(hash)
            }
            winners.append(winner)
            contributions[winner.modArchive, default: 0] += 1
        }

        // Most-contributing mod wins; ASCII path order breaks ties so template
        // selection is independent of dictionary iteration order.
        let templateURL = contributions.keys.sorted {
            let lhsCount = contributions[$0] ?? 0
            let rhsCount = contributions[$1] ?? 0
            return lhsCount == rhsCount ? $0.path < $1.path : lhsCount > rhsCount
        }[0]
        return try RDARWriter.write(
            winners: winners,
            headerTemplate: source(templateURL),
            to: game.managedLooseArchive
        )
    }

    private func patchSummary(targetURL: URL, writes: [PlannedWrite]) throws -> PatchSummary {
        let summary = try patch(targetURL: targetURL, writes: writes)
        return PatchSummary(
            backupDirectory: summary.backupDirectory,
            patchedCount: summary.patchedCount,
            insertedCount: summary.insertedCount,
            replacedCount: summary.replacedCount,
            targetArchive: summary.targetArchive
        )
    }

    // MARK: - The write

    /// Rewrites one target archive, applying every planned write in one pass.
    ///
    /// Each write's source record is transplanted **verbatim**: all 56 bytes are
    /// copied from the mod, and only the two range pairs — which index tables
    /// that exist per-archive and are meaningless outside their own — are
    /// recomputed. Taking the stock record as the base and overwriting named
    /// fields is what silently left `timestamp` and `numInlineBufferSegments`
    /// describing the stock resource while the payload was the mod's.
    private func patch(targetURL: URL, writes: [PlannedWrite]) throws -> ArchivePatchSummary {
        let target = try RDARArchive.read(targetURL)

        var targetRecordsByHash: [UInt64: [RDARRecord]] = [:]
        for record in target.records {
            targetRecordsByHash[record.nameHash, default: []].append(record)
        }

        var seen = Set<UInt64>()
        for write in writes {
            guard seen.insert(write.hash).inserted else {
                throw RDARArchiveError.duplicatePatch(write.hash)
            }
        }

        // A hash appearing more than once in the target is only safe to replace
        // wholesale when every copy holds the same payload.
        for hash in seen.sorted() {
            let records = targetRecordsByHash[hash] ?? []
            guard records.count > 1 else { continue }
            let first = try compressedData(for: records[0], in: target)
            for record in records.dropFirst() where try compressedData(for: record, in: target) != first {
                throw RDARArchiveError.ambiguousTargetRecord(hash, targetURL)
            }
        }

        let backup = try BackupStore(game: game).createBackup(
            targetArchive: targetURL,
            sourceArchive: writes.first?.source.url,
            note: "before applying \(writes.count) records"
        )

        let added = writes.filter { targetRecordsByHash[$0.hash] == nil }
        let newRecordBytes = added.count * 56
        let newSegmentBytes = writes.reduce(0) { $0 + $1.record.segmentCount * 16 }
        let newDependencyBytes = writes.reduce(0) { $0 + $1.dependencies.count * 8 }
        let grownBytes = newRecordBytes + newSegmentBytes + newDependencyBytes

        var patchedIndex = Data(count: target.indexData.count + grownBytes)

        var indexHeader = target.indexData[0..<target.recordsOffset]
        try indexHeader.writeUInt32LE(try target.indexData.uint32LE(at: 4) + UInt32(grownBytes), at: 4)
        try indexHeader.writeUInt32LE(target.fileEntryCount + UInt32(added.count), at: 16)
        try indexHeader.writeUInt32LE(target.fileSegmentCount + UInt32(newSegmentBytes / 16), at: 20)
        // Never written before this change. Appending dependency bytes without
        // it yields an index whose CRC is valid and whose count is wrong.
        try indexHeader.writeUInt32LE(target.dependencyCount + UInt32(newDependencyBytes / 8), at: 24)
        patchedIndex.replaceSubrange(0..<target.recordsOffset, with: indexHeader)

        let sortedRecords = (target.records.map { ($0.nameHash, $0.bytes) } + added.map { ($0.hash, $0.record.bytes) })
            .sorted { lhs, rhs in
                if lhs.0 == rhs.0 { return false }
                return lhs.0 < rhs.0
            }
        var recordOffsets: [UInt64: [Int]] = [:]
        var recordTableOffset = target.recordsOffset
        for (hash, bytes) in sortedRecords {
            patchedIndex.replaceSubrange(recordTableOffset..<recordTableOffset + 56, with: bytes)
            recordOffsets[hash, default: []].append(recordTableOffset)
            recordTableOffset += 56
        }

        let patchedSegmentsOffset = target.recordsOffset + sortedRecords.count * 56
        patchedIndex.replaceSubrange(
            patchedSegmentsOffset..<patchedSegmentsOffset + Int(target.fileSegmentCount) * 16,
            with: target.indexData[target.segmentsOffset..<target.dependenciesOffset]
        )
        let patchedDependenciesOffset = patchedSegmentsOffset + Int(target.fileSegmentCount) * 16 + newSegmentBytes
        let existingDependencyBytes = target.indexData.count - target.dependenciesOffset
        patchedIndex.replaceSubrange(
            patchedDependenciesOffset..<patchedDependenciesOffset + existingDependencyBytes,
            with: target.indexData[target.dependenciesOffset..<target.indexData.count]
        )

        let targetHandle = try FileHandle(forUpdating: targetURL)
        var sourceHandles: [URL: FileHandle] = [:]
        defer {
            try? targetHandle.close()
            for handle in sourceHandles.values { try? handle.close() }
        }
        func sourceHandle(_ url: URL) throws -> FileHandle {
            if let handle = sourceHandles[url] { return handle }
            let handle = try FileHandle(forReadingFrom: url)
            sourceHandles[url] = handle
            return handle
        }

        let currentSize = try FileManager.default.attributesOfItem(atPath: targetURL.path)[.size] as? NSNumber
        var appendOffset = currentSize?.uint64Value ?? target.fileSize
        var appendedSegmentIndex = target.fileSegmentCount
        var appendedSegmentTableOffset = patchedSegmentsOffset + Int(target.fileSegmentCount) * 16
        var appendedDependencyIndex = target.dependencyCount
        var appendedDependencyTableOffset = patchedDependenciesOffset + existingDependencyBytes

        for write in writes {
            let handle = try sourceHandle(write.source.url)

            let newSegmentsStart = appendedSegmentIndex
            for i in 0..<write.record.segmentCount {
                let sourceSegment = write.source.segments[Int(write.record.segmentsStart) + i]
                try handle.seek(toOffset: sourceSegment.offset)
                let compressedData = try handle.read(upToCount: Int(sourceSegment.compressedSize)) ?? Data()
                guard compressedData.count == Int(sourceSegment.compressedSize) else {
                    throw BinaryError.shortRead(write.source.url, Int(sourceSegment.compressedSize))
                }

                try targetHandle.seek(toOffset: appendOffset)
                try targetHandle.write(contentsOf: compressedData)

                try patchedIndex.writeUInt64LE(appendOffset, at: appendedSegmentTableOffset)
                try patchedIndex.writeUInt32LE(sourceSegment.compressedSize, at: appendedSegmentTableOffset + 8)
                try patchedIndex.writeUInt32LE(sourceSegment.size, at: appendedSegmentTableOffset + 12)

                appendOffset += UInt64(sourceSegment.compressedSize)
                appendedSegmentIndex += 1
                appendedSegmentTableOffset += 16
            }

            // The dependency table is last in the index and record slices are
            // never shared, so appending leaves every existing range valid.
            let newDependenciesStart = appendedDependencyIndex
            for dependency in write.dependencies {
                try patchedIndex.writeUInt64LE(dependency, at: appendedDependencyTableOffset)
                appendedDependencyIndex += 1
                appendedDependencyTableOffset += 8
            }

            guard let offsets = recordOffsets[write.hash], !offsets.isEmpty else {
                throw RDARArchiveError.planMissingWinner(write.hash)
            }
            for recordOffset in offsets {
                patchedIndex.replaceSubrange(recordOffset..<recordOffset + 56, with: write.record.bytes)
                try patchedIndex.writeUInt32LE(newSegmentsStart, at: recordOffset + 20)
                try patchedIndex.writeUInt32LE(appendedSegmentIndex, at: recordOffset + 24)
                try patchedIndex.writeUInt32LE(newDependenciesStart, at: recordOffset + 28)
                try patchedIndex.writeUInt32LE(appendedDependencyIndex, at: recordOffset + 32)
            }
        }

        try patchedIndex.writeUInt64LE(Hashes.crc64(patchedIndex.subdata(in: 16..<patchedIndex.count)), at: 8)

        let newIndexPosition = alignUp(appendOffset, to: 4096)
        if newIndexPosition > appendOffset {
            try targetHandle.seek(toOffset: appendOffset)
            try targetHandle.write(contentsOf: Data(count: Int(newIndexPosition - appendOffset)))
        }
        try targetHandle.seek(toOffset: newIndexPosition)
        try targetHandle.write(contentsOf: patchedIndex)

        let indexEnd = newIndexPosition + UInt64(patchedIndex.count)
        let newFileSize = alignUp(indexEnd, to: 4096)
        if newFileSize > indexEnd {
            try targetHandle.seek(toOffset: indexEnd)
            try targetHandle.write(contentsOf: Data(count: Int(newFileSize - indexEnd)))
        }
        try targetHandle.truncate(atOffset: newFileSize)

        var header = target.header
        try header.writeUInt64LE(newIndexPosition, at: 8)
        try header.writeUInt32LE(UInt32(patchedIndex.count), at: 16)
        try header.writeUInt64LE(newFileSize, at: 32)
        try targetHandle.seek(toOffset: 0)
        try targetHandle.write(contentsOf: header)

        return ArchivePatchSummary(
            targetArchive: targetURL,
            backupDirectory: backup,
            patchedCount: writes.count,
            insertedCount: added.count,
            replacedCount: writes.count - added.count
        )
    }

    private func compressedData(for record: RDARRecord, in archive: RDARArchive) throws -> Data {
        var data = Data()
        for i in 0..<record.segmentCount {
            let segment = archive.segments[Int(record.segmentsStart) + i]
            data.append(try readData(url: archive.url, offset: segment.offset, count: Int(segment.compressedSize)))
        }
        return data
    }
}

/// One record to write into one target archive, carrying its own source.
///
/// Records applied to a single target now originate from several mods, so the
/// source archive travels with the write rather than being fixed per call.
private struct PlannedWrite {
    let hash: UInt64
    let source: RDARArchive
    let record: RDARRecord
    let dependencies: [UInt64]
}
