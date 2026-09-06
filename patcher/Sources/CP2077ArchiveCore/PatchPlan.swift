import Foundation

/// The mod record chosen to supply a given resource hash.
public struct WinningRecord: Sendable {
    public let hash: UInt64
    public let modArchive: URL
    public let record: RDARRecord
    public let dependencies: [UInt64]
}

/// A mod record that lost a conflict and will not be applied.
public struct LosingRecord: Sendable {
    public let hash: UInt64
    public let modArchive: URL
    public let winnerArchive: URL
}

/// Everything decided before a single byte is written.
///
/// The plan is the artifact `patch` applies and `verify` checks against, so both
/// agree on what the install is supposed to contain.
public struct PatchPlan: Sendable {
    /// Every mod considered by the plan, in ASCII path order.
    public let mods: [URL]
    /// One winning mod record per resource hash.
    public let winners: [UInt64: WinningRecord]
    /// Every official archive owning a winning hash, and the hashes to write there.
    public let officialWork: [URL: [UInt64]]
    /// Winning hashes no official archive owns; these ship as loose archives.
    public let newResources: [UInt64]
    /// Records dropped because an earlier mod already claimed the hash.
    public let losers: [LosingRecord]

    public init(
        mods: [URL] = [],
        winners: [UInt64: WinningRecord],
        officialWork: [URL: [UInt64]],
        newResources: [UInt64],
        losers: [LosingRecord]
    ) {
        self.mods = mods.map(\.normalizedFileURL).sorted { $0.path < $1.path }
        self.winners = winners
        self.officialWork = officialWork
        self.newResources = newResources
        self.losers = losers
    }

    /// Official archives to rewrite, in a stable order.
    public var targets: [URL] {
        officialWork.keys.sorted { $0.path < $1.path }
    }

    public var overrideCount: Int {
        winners.count - newResources.count
    }
}

public enum PatchPlanner {
    /// Builds a plan from the mods and the install's official archives.
    ///
    /// Mods are walked in ASCII path order, matching the `find | sort -z` order
    /// `inject_archives.sh` feeds in, and the **first** mod to claim a hash wins.
    /// The write mechanism is inherently last-wins, so the Windows "first archive
    /// wins" rule has to be resolved here, before anything is written.
    ///
    /// Every official archive owning a winning hash gets work, not just the
    /// lexicographically first: which copy the depot actually reads is unknown,
    /// so all of them are made to carry the mod's data.
    public static func plan(mods: [URL], game: GameInstall) throws -> PatchPlan {
        try plan(mods: mods, officialArchives: try game.officialMacArchives())
    }

    public static func plan(mods: [URL], officialArchives: [URL]) throws -> PatchPlan {
        var ownersByHash: [UInt64: [URL]] = [:]
        for archiveURL in officialArchives.map(\.normalizedFileURL).sorted(by: { $0.path < $1.path }) {
            let archive = try RDARArchive.read(archiveURL)
            for record in archive.records where ownersByHash[record.nameHash]?.last != archiveURL {
                ownersByHash[record.nameHash, default: []].append(archiveURL)
            }
        }

        var winners: [UInt64: WinningRecord] = [:]
        var losers: [LosingRecord] = []
        var claimOrder: [UInt64] = []

        for modURL in mods.map(\.normalizedFileURL).sorted(by: { $0.path < $1.path }) {
            let mod = try RDARArchive.read(modURL)
            for record in mod.records {
                if let existing = winners[record.nameHash] {
                    guard existing.modArchive != modURL else { continue }
                    losers.append(LosingRecord(
                        hash: record.nameHash,
                        modArchive: modURL,
                        winnerArchive: existing.modArchive
                    ))
                    continue
                }
                winners[record.nameHash] = WinningRecord(
                    hash: record.nameHash,
                    modArchive: modURL,
                    record: record,
                    dependencies: try mod.dependencies(for: record)
                )
                claimOrder.append(record.nameHash)
            }
        }

        var officialWork: [URL: [UInt64]] = [:]
        var newResources: [UInt64] = []
        for hash in claimOrder {
            guard let owners = ownersByHash[hash], !owners.isEmpty else {
                newResources.append(hash)
                continue
            }
            for owner in owners {
                officialWork[owner, default: []].append(hash)
            }
        }

        return PatchPlan(
            mods: mods,
            winners: winners,
            officialWork: officialWork.mapValues { $0.sorted() },
            newResources: newResources,
            losers: losers
        )
    }
}
