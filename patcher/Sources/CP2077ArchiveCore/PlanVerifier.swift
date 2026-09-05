import Foundation

public enum RecordVerdict: String, Sendable {
    /// Every planned field is present on disk.
    case matchesPlan
    /// Some of the plan was applied and some was not.
    case differsFromPlan
    /// Nothing of the plan reached this record; it still looks like stock.
    case unpatchedStockRecord
}

public struct RecordVerification: Sendable {
    public let hash: UInt64
    public let verdict: RecordVerdict
    public let issues: [String]
}

public struct ArchiveVerification: Sendable {
    public let archive: URL
    /// Archive-level problems: CRC, alignment, header counts.
    public let issues: [String]
    public let records: [RecordVerification]

    public var isClean: Bool {
        issues.isEmpty && records.allSatisfy { $0.verdict == .matchesPlan }
    }
}

public struct VerificationReport: Sendable {
    public let archives: [ArchiveVerification]

    public var isClean: Bool {
        archives.allSatisfy(\.isClean)
    }

    public var matchingRecordCount: Int {
        count(of: .matchesPlan)
    }

    public var differingRecordCount: Int {
        count(of: .differsFromPlan)
    }

    public var unpatchedRecordCount: Int {
        count(of: .unpatchedStockRecord)
    }

    private func count(of verdict: RecordVerdict) -> Int {
        archives.reduce(0) { $0 + $1.records.filter { $0.verdict == verdict }.count }
    }
}

/// Checks the bytes on disk against the plan that was supposed to produce them.
///
/// The old `verify` checked index CRC and alignment only, which every one of the
/// transplant defects passed. Recomputing the plan and comparing field by field
/// is the only way those are detectable at all.
public enum PlanVerifier {
    public static func verify(plan: PatchPlan, game: GameInstall) throws -> VerificationReport {
        let officialURLs = Set(try game.officialMacArchives())
        var officialHashes = Set<UInt64>()
        var archives: [ArchiveVerification] = []
        let looseURL = game.managedLooseArchive.normalizedFileURL
        var foundLooseArchive = false
        var deferredLooseArchive: RDARArchive?
        for archiveURL in try game.macArchives() {
            if archiveURL == looseURL {
                foundLooseArchive = true
                deferredLooseArchive = try RDARArchive.read(archiveURL)
            } else {
                let archive = try RDARArchive.read(archiveURL)
                if officialURLs.contains(archiveURL) {
                    officialHashes.formUnion(archive.records.map(\.nameHash))
                }
                var verification = try verify(plan: plan, archive: archive)
                if archiveURL.lastPathComponent.hasPrefix("basegame_99_") {
                    verification = ArchiveVerification(
                        archive: verification.archive,
                        issues: verification.issues + [
                            "unexpected loose archive; the plan uses only \(looseURL.lastPathComponent)"
                        ],
                        records: verification.records
                    )
                }
                archives.append(verification)
            }
        }

        if let loose = deferredLooseArchive {
            archives.append(try verifyLoose(plan: plan, archive: loose, officialHashes: officialHashes))
        }

        if !plan.newResources.isEmpty && !foundLooseArchive {
            archives.append(ArchiveVerification(
                archive: looseURL,
                issues: ["planned consolidated loose archive is absent"],
                records: plan.newResources.sorted().compactMap { hash in
                    guard plan.winners[hash] != nil else { return nil }
                    return RecordVerification(
                        hash: hash,
                        verdict: .differsFromPlan,
                        issues: ["record is absent from \(looseURL.lastPathComponent)"]
                    )
                }
            ))
        }
        return VerificationReport(archives: archives)
    }

    static func verify(plan: PatchPlan, archiveURL: URL) throws -> ArchiveVerification {
        try verify(plan: plan, archive: RDARArchive.read(archiveURL))
    }

    private static func verify(plan: PatchPlan, archive: RDARArchive) throws -> ArchiveVerification {
        let issues = try structuralIssues(in: archive)

        let hashes = plan.officialWork[archive.url.normalizedFileURL] ?? []
        var records: [RecordVerification] = []
        for hash in hashes {
            guard let winner = plan.winners[hash] else { continue }
            records.append(verify(winner: winner, in: archive))
        }

        return ArchiveVerification(archive: archive.url, issues: issues, records: records)
    }

    private static func verifyLoose(
        plan: PatchPlan,
        archive: RDARArchive,
        officialHashes: Set<UInt64>
    ) throws -> ArchiveVerification {
        var issues = try structuralIssues(in: archive)
        let expectedHashes = Set(plan.newResources)
        var counts: [UInt64: Int] = [:]
        for record in archive.records {
            counts[record.nameHash, default: 0] += 1
            if officialHashes.contains(record.nameHash) {
                issues.append("record \(Hashes.hex64(record.nameHash)) is owned by an official archive")
            }
            if !expectedHashes.contains(record.nameHash) {
                issues.append("unexpected record \(Hashes.hex64(record.nameHash)) is not a planned new resource")
            }
        }

        var records: [RecordVerification] = []
        for hash in plan.newResources.sorted() {
            let count = counts[hash] ?? 0
            if count != 1 {
                issues.append("planned new resource \(Hashes.hex64(hash)) occurs \(count) times; expected exactly once")
            }
            guard let winner = plan.winners[hash] else { continue }
            records.append(verify(winner: winner, in: archive))
        }

        if plan.newResources.isEmpty {
            issues.append("consolidated loose archive exists but the plan has no new resources")
        }
        return ArchiveVerification(archive: archive.url, issues: issues, records: records)
    }

    private static func structuralIssues(in archive: RDARArchive) throws -> [String] {
        var issues: [String] = []

        if archive.storedCRC != archive.computedCRC {
            issues.append("index CRC mismatch")
        }
        if archive.indexPosition % 4096 != 0 {
            issues.append("index position \(archive.indexPosition) is not 4096-aligned")
        }
        if archive.fileSize % 4096 != 0 {
            issues.append("file size \(archive.fileSize) is not 4096-aligned")
        }
        if try archive.indexData.uint32LE(at: 0) != 8 {
            issues.append("index header offset 0 is not 8")
        }
        if try archive.indexData.uint32LE(at: 4) != archive.indexSize - 8 {
            issues.append("index header size does not equal indexSize - 8")
        }

        let actualFileSize = try archive.url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        if actualFileSize.map(UInt64.init) != archive.fileSize {
            issues.append("header file size \(archive.fileSize) does not match the file on disk")
        }
        if archive.indexPosition > archive.fileSize
            || UInt64(archive.indexSize) > archive.fileSize - archive.indexPosition
        {
            issues.append("index runs past the end of the file")
        }

        // Header counts must agree with the tables they describe, or an index
        // can be structurally valid and still misdescribe itself.
        let expectedIndexSize = 28
            + Int(archive.fileEntryCount) * 56
            + Int(archive.fileSegmentCount) * 16
            + Int(archive.dependencyCount) * 8
        if expectedIndexSize != archive.indexData.count {
            issues.append(
                "header counts describe \(expectedIndexSize) index bytes but the index is \(archive.indexData.count)"
                    + " (entries=\(archive.fileEntryCount) segments=\(archive.fileSegmentCount)"
                    + " dependencyCount=\(archive.dependencyCount))"
            )
        }

        for record in archive.records {
            if record.segmentsStart > record.segmentsEnd || record.segmentsEnd > archive.fileSegmentCount {
                issues.append("record \(Hashes.hex64(record.nameHash)) has a segment range outside the segment table")
            }
            if record.dependenciesStart > record.dependenciesEnd || record.dependenciesEnd > archive.dependencyCount {
                issues.append("record \(Hashes.hex64(record.nameHash)) has a dependency range outside dependencyCount")
            }
        }
        for segment in archive.segments {
            if segment.offset > archive.fileSize
                || UInt64(segment.compressedSize) > archive.fileSize - segment.offset
            {
                issues.append("segment \(segment.index) runs past the end of the file")
            }
        }
        return issues
    }

    private static func verify(winner: WinningRecord, in archive: RDARArchive) -> RecordVerification {
        let copies = archive.records.filter { $0.nameHash == winner.hash }
        guard !copies.isEmpty else {
            return RecordVerification(
                hash: winner.hash,
                verdict: .differsFromPlan,
                issues: ["record is absent from \(archive.url.lastPathComponent)"]
            )
        }

        var issues: [String] = []
        var matchedFields = 0
        var plannedFields = 0

        for record in copies {
            let expected = winner.record

            plannedFields += 1
            if record.timestamp == expected.timestamp {
                matchedFields += 1
            } else {
                issues.append("timestamp is \(record.timestamp), plan says \(expected.timestamp)")
            }

            plannedFields += 1
            if record.numInlineBufferSegments == expected.numInlineBufferSegments {
                matchedFields += 1
            } else {
                issues.append(
                    "inline buffer segments is \(record.numInlineBufferSegments),"
                        + " plan says \(expected.numInlineBufferSegments)"
                )
            }

            plannedFields += 1
            if record.sha1 == expected.sha1 {
                matchedFields += 1
            } else {
                issues.append("sha1 does not match the plan")
            }

            // An empty list matching an empty list is not evidence that
            // anything was applied, so it does not count towards the verdict.
            if !winner.dependencies.isEmpty { plannedFields += 1 }
            let onDisk = (try? archive.dependencies(for: record)) ?? []
            if onDisk == winner.dependencies {
                if !winner.dependencies.isEmpty { matchedFields += 1 }
            } else {
                issues.append(
                    "dependencies are \(onDisk.map(Hashes.hex64)), plan says \(winner.dependencies.map(Hashes.hex64))"
                )
            }

            if record.segmentCount != expected.segmentCount {
                issues.append("segment count is \(record.segmentCount), plan says \(expected.segmentCount)")
            }
            if record.segmentsStart > record.segmentsEnd || record.segmentsEnd > archive.fileSegmentCount {
                issues.append(
                    "segment range \(record.segmentsStart)..<\(record.segmentsEnd)"
                        + " is outside the segment table of \(archive.fileSegmentCount)"
                )
            } else {
                for i in Int(record.segmentsStart)..<Int(record.segmentsEnd) {
                    let segment = archive.segments[i]
                    if segment.offset > archive.fileSize
                        || UInt64(segment.compressedSize) > archive.fileSize - segment.offset
                    {
                        issues.append("segment \(i) runs past the end of the file")
                    }
                }
            }
            if record.dependenciesStart > record.dependenciesEnd || record.dependenciesEnd > archive.dependencyCount {
                issues.append(
                    "dependency range \(record.dependenciesStart)..<\(record.dependenciesEnd)"
                        + " is outside dependencyCount \(archive.dependencyCount)"
                )
            }
        }

        let verdict: RecordVerdict
        if issues.isEmpty {
            verdict = .matchesPlan
        } else if matchedFields == 0 && plannedFields > 0 {
            // Not one planned field landed, so the plan never reached this
            // record: a crashed run, or an owner the patch skipped.
            verdict = .unpatchedStockRecord
        } else {
            verdict = .differsFromPlan
        }
        return RecordVerification(hash: winner.hash, verdict: verdict, issues: issues)
    }
}
