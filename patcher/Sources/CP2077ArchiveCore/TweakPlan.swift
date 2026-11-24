import Foundation

public enum TweakPlanError: Error, CustomStringConvertible {
    case invalidDocument(URL, String)
    case missingSelectedBlob(URL, String, TweakBlobSelector)
    case missingTarget(URL, String)
    case unsupportedOperation(URL, String, String)

    public var description: String {
        switch self {
        case let .invalidDocument(url, detail):
            return url.lastPathComponent + ": " + detail
        case let .missingSelectedBlob(mod, flat, selector):
            return mod.lastPathComponent + ": " + flat + " selects " + selector.rawValue + ","
                + " but that TweakDB blob is absent from the published baseline"
        case let .missingTarget(mod, flat):
            return mod.lastPathComponent + ": no published TweakDB blob owns " + flat
        case let .unsupportedOperation(mod, flat, detail):
            return mod.lastPathComponent + ": unsupported operation for " + flat + ": " + detail
        }
    }
}

public struct TweakWork: Sendable {
    public let operation: TweakOperation
    public let mod: URL

    public init(operation: TweakOperation, mod: URL) {
        self.operation = operation
        self.mod = mod
    }
}

/// An operation dropped because an earlier mod already claimed the same flat
/// in the same target blob.
public struct TweakLoser: Sendable {
    public let flat: String
    public let mod: URL
    public let winner: URL
    public let selector: TweakBlobSelector?

    public init(
        flat: String,
        mod: URL,
        winner: URL,
        selector: TweakBlobSelector? = nil
    ) {
        self.flat = flat
        self.mod = mod
        self.winner = winner
        self.selector = selector
    }
}

/// All decisions made before a builder is allowed to write a generated blob.
public struct TweakPlan: Sendable {
    public let mods: [URL]
    public let workByBlob: [URL: [TweakWork]]
    public let losers: [TweakLoser]
    public let unsupported: [String]

    public init(
        mods: [URL],
        workByBlob: [URL: [TweakWork]],
        losers: [TweakLoser],
        unsupported: [String]
    ) {
        self.mods = mods
        self.workByBlob = workByBlob
        self.losers = losers
        self.unsupported = unsupported
    }

    public var targets: [URL] {
        workByBlob.keys.sorted { utf8Precedes($0.path, $1.path) }
    }

    public var operationCount: Int {
        workByBlob.values.reduce(0) { $0 + $1.count }
    }

    public var isEmpty: Bool {
        operationCount == 0
    }
}

public enum TweakPlanner {
    /// Resolves normalized operations against the published baseline blobs.
    ///
    /// Mods are sorted by their complete UTF-8 path. An unselected operation
    /// targets every present blob that owns the flat; an explicit `base` or
    /// `ep1` selector targets only that named blob. The first ordered mod to
    /// claim a flat in a target blob wins, and later claims are reported.
    public static func plan(mods: [URL], blobs: [URL]) throws -> TweakPlan {
        let orderedMods = mods.map(\.normalizedFileURL).sorted {
            utf8Precedes($0.path, $1.path)
        }
        let orderedBlobs = blobs.map(\.normalizedFileURL).sorted {
            utf8Precedes($0.path, $1.path)
        }

        var parsedBlobs: [URL: TweakBlob] = [:]
        for blobURL in orderedBlobs {
            parsedBlobs[blobURL] = try TweakBlob.read(blobURL)
        }

        var workByBlob: [URL: [TweakWork]] = [:]
        var claims: [String: URL] = [:]
        var reportedLosers = Set<String>()
        var losers: [TweakLoser] = []

        for modURL in orderedMods {
            let operations: [TweakOperation]
            do {
                operations = try TweakDocument.parse(contentsOf: modURL)
            } catch {
                throw TweakPlanError.invalidDocument(modURL, String(describing: error))
            }

            for operation in operations {
                let selector = operation.selector
                let candidateBlobs: [URL]
                if let selector {
                    guard let selected = orderedBlobs.first(where: {
                        $0.lastPathComponent == selector.fileName
                    }) else {
                        throw TweakPlanError.missingSelectedBlob(
                            modURL,
                            operation.targetFlat,
                            selector
                        )
                    }
                    candidateBlobs = [selected]
                } else {
                    candidateBlobs = orderedBlobs.filter {
                        parsedBlobs[$0]?.find(flat: operation.targetFlat) != nil
                    }
                }

                guard !candidateBlobs.isEmpty else {
                    throw TweakPlanError.missingTarget(modURL, operation.targetFlat)
                }

                for blobURL in candidateBlobs {
                    guard let blob = parsedBlobs[blobURL],
                          let located = blob.find(flat: operation.targetFlat) else {
                        throw TweakPlanError.missingTarget(modURL, operation.targetFlat)
                    }
                    switch operation {
                    case .assign:
                        break
                    case .arrayAppend, .arrayRemove:
                        guard case .array = blob.blocks[located.blockIndex].type else {
                            throw TweakPlanError.unsupportedOperation(
                                modURL,
                                operation.targetFlat,
                                "array append/remove requires an array flat"
                            )
                        }
                    }

                    let claimKey = blobURL.path + "\u{0}" + operation.targetFlat
                    if let winner = claims[claimKey] {
                        let loserKey = modURL.path + "\u{0}" + operation.targetFlat
                            + "\u{0}" + (selector?.rawValue ?? "")
                        if reportedLosers.insert(loserKey).inserted {
                            losers.append(TweakLoser(
                                flat: operation.targetFlat,
                                mod: modURL,
                                winner: winner,
                                selector: selector
                            ))
                        }
                        continue
                    }

                    claims[claimKey] = modURL
                    workByBlob[blobURL, default: []].append(
                        TweakWork(operation: operation, mod: modURL)
                    )
                }
            }
        }

        return TweakPlan(
            mods: orderedMods,
            workByBlob: workByBlob,
            losers: losers,
            unsupported: []
        )
    }
}

private extension TweakOperation {
    var selector: TweakBlobSelector? {
        switch self {
        case let .assign(_, selector, _): return selector
        case let .arrayAppend(_, selector, _): return selector
        case let .arrayRemove(_, selector, _): return selector
        }
    }
}

private extension TweakBlobSelector {
    var fileName: String {
        switch self {
        case .base: return "tweakdb.bin"
        case .ep1: return "tweakdb_ep1.bin"
        }
    }
}

private func utf8Precedes(_ left: String, _ right: String) -> Bool {
    Array(left.utf8).lexicographicallyPrecedes(Array(right.utf8))
}
