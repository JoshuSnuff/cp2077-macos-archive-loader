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
        var archives: [ArchiveVerification] = []
        for archiveURL in try game.macArchives() {
            archives.append(try verify(plan: plan, archiveURL: archiveURL))
        }
        return VerificationReport(archives: archives)
    }

    static func verify(plan: PatchPlan, archiveURL: URL) throws -> ArchiveVerification {
        let archive = try RDARArchive.read(archiveURL)
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
        if archive.records.map(\.dependenciesEnd).max() ?? 0 > archive.dependencyCount {
            issues.append("a record's dependency range runs past dependencyCount \(archive.dependencyCount)")
        }

        let hashes = plan.officialWork[archiveURL.normalizedFileURL] ?? []
        var records: [RecordVerification] = []
        for hash in hashes {
            guard let winner = plan.winners[hash] else { continue }
            records.append(verify(winner: winner, in: archive))
        }

        return ArchiveVerification(archive: archiveURL, issues: issues, records: records)
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
                    if segment.offset + UInt64(segment.compressedSize) > archive.fileSize {
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
