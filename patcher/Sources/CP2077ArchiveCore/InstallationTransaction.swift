import Darwin
import Foundation

public enum InstallationTransactionPhase: String, Codable, Sendable {
    case snapshotting
    case prepared
    case staged
    case replacing
    case committed
    case removing
    case rolledBack = "rolled-back"
}

public struct InstallationSourceHash: Codable, Equatable, Sendable {
    public let packagePath: String
    public let expectedSHA256: String
    public let actualSHA256: String
}

public struct InstallationManagedMapping: Codable, Equatable, Sendable {
    public let packagePath: String
    public let gamePath: String
    public let expectedSHA256: String
    public var installedSHA256: String?
}

public struct InstallationTransactionMarker: Codable, Equatable, Sendable {
    public let transactionID: String
    public var phase: InstallationTransactionPhase
    public let generation: UInt64
    public let parentTransactionID: String?
    public let manifestSelfHash: String
    public let targetIdentity: CompatibilityTarget
    public let sourcePackageHashes: [InstallationSourceHash]
    public let snapshotPath: String
    public let stagingPath: String
    public var managedMappings: [InstallationManagedMapping]
    fileprivate let isLegacyLineage: Bool

    public init(
        transactionID: String,
        phase: InstallationTransactionPhase,
        manifestSelfHash: String,
        targetIdentity: CompatibilityTarget,
        sourcePackageHashes: [InstallationSourceHash],
        snapshotPath: String,
        stagingPath: String,
        managedMappings: [InstallationManagedMapping],
        generation: UInt64 = 0,
        parentTransactionID: String? = nil
    ) {
        self.transactionID = transactionID
        self.phase = phase
        self.generation = generation
        self.parentTransactionID = parentTransactionID
        self.manifestSelfHash = manifestSelfHash
        self.targetIdentity = targetIdentity
        self.sourcePackageHashes = sourcePackageHashes
        self.snapshotPath = snapshotPath
        self.stagingPath = stagingPath
        self.managedMappings = managedMappings
        self.isLegacyLineage = false
    }

    private enum CodingKeys: String, CodingKey {
        case transactionID
        case phase
        case generation
        case parentTransactionID
        case manifestSelfHash
        case targetIdentity
        case sourcePackageHashes
        case snapshotPath
        case stagingPath
        case managedMappings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hasGeneration = container.contains(.generation)
        let hasParentTransactionID = container.contains(.parentTransactionID)
        transactionID = try container.decode(String.self, forKey: .transactionID)
        phase = try container.decode(InstallationTransactionPhase.self, forKey: .phase)
        generation = try container.decodeIfPresent(UInt64.self, forKey: .generation) ?? 0
        parentTransactionID = try container.decodeIfPresent(String.self, forKey: .parentTransactionID)
        manifestSelfHash = try container.decode(String.self, forKey: .manifestSelfHash)
        targetIdentity = try container.decode(CompatibilityTarget.self, forKey: .targetIdentity)
        sourcePackageHashes = try container.decode([InstallationSourceHash].self, forKey: .sourcePackageHashes)
        snapshotPath = try container.decode(String.self, forKey: .snapshotPath)
        stagingPath = try container.decode(String.self, forKey: .stagingPath)
        managedMappings = try container.decode([InstallationManagedMapping].self, forKey: .managedMappings)
        isLegacyLineage = !hasGeneration && !hasParentTransactionID
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(transactionID, forKey: .transactionID)
        try container.encode(phase, forKey: .phase)
        if !isLegacyLineage {
            try container.encode(generation, forKey: .generation)
            try container.encodeIfPresent(parentTransactionID, forKey: .parentTransactionID)
        }
        try container.encode(manifestSelfHash, forKey: .manifestSelfHash)
        try container.encode(targetIdentity, forKey: .targetIdentity)
        try container.encode(sourcePackageHashes, forKey: .sourcePackageHashes)
        try container.encode(snapshotPath, forKey: .snapshotPath)
        try container.encode(stagingPath, forKey: .stagingPath)
        try container.encode(managedMappings, forKey: .managedMappings)
    }
}

/// Read-only view of the durable installation records and the legacy
/// compatibility installation. The latter is synthesized in memory as
/// generation zero until an explicit removal migrates it into the sole
/// durable transaction marker.
public struct InstallationTransactionInspection: Equatable, Sendable {
    public let committed: [InstallationTransactionMarker]
    public let interrupted: [InstallationTransactionMarker]
    public let rolledBack: [InstallationTransactionMarker]
    public let generationZero: InstallationTransactionMarker?
    public let current: InstallationTransactionMarker?

    public init(
        committed: [InstallationTransactionMarker],
        interrupted: [InstallationTransactionMarker],
        rolledBack: [InstallationTransactionMarker],
        generationZero: InstallationTransactionMarker?,
        current: InstallationTransactionMarker?
    ) {
        self.committed = committed
        self.interrupted = interrupted
        self.rolledBack = rolledBack
        self.generationZero = generationZero
        self.current = current
    }
}

public struct InstallationSnapshotEntry: Codable, Equatable, Sendable {
    public let gamePath: String
    public let wasPresent: Bool
    public let mode: UInt16?
    public let sha256: String?
}

public struct InstallationSnapshot: Codable, Equatable, Sendable {
    public let transactionID: String
    public let manifestSelfHash: String
    public let targetIdentity: CompatibilityTarget
    public let entries: [InstallationSnapshotEntry]
    public let complete: Bool
}

public enum InstallationTransactionError: Error, CustomStringConvertible {
    case invalidTransactionID(String)
    case transactionAlreadyExists(String)
    case transactionNotFound(String)
    case corruptMarker(String)
    case invalidTransition(id: String, expected: InstallationTransactionPhase, actual: InstallationTransactionPhase)
    case invalidManagedFile(path: String, reason: String)
    case snapshotInvalid(id: String, reason: String)
    case stagedFileInvalid(path: String, reason: String)
    case installedFileInvalid(path: String, reason: String)
    case transactionNotCurrent(String)
    case installFailed(String)
    case rollbackFailed(original: String, rollback: String)
    case durabilityFailure(String)

    public var description: String {
        switch self {
        case let .invalidTransactionID(id):
            return "invalid installation transaction id: \(id)"
        case let .transactionAlreadyExists(id):
            return "installation transaction already exists: \(id)"
        case let .transactionNotFound(id):
            return "installation transaction not found: \(id)"
        case let .corruptMarker(reason):
            return "installation transaction marker is corrupt: \(reason)"
        case let .invalidTransition(id, expected, actual):
            return "installation transaction \(id) is \(actual.rawValue), expected \(expected.rawValue)"
        case let .invalidManagedFile(path, reason):
            return "invalid managed file \(path): \(reason)"
        case let .snapshotInvalid(id, reason):
            return "installation snapshot \(id) is invalid: \(reason)"
        case let .stagedFileInvalid(path, reason):
            return "staged managed file \(path) is invalid: \(reason)"
        case let .installedFileInvalid(path, reason):
            return "installed managed file \(path) is invalid: \(reason)"
        case let .transactionNotCurrent(id):
            return "installation transaction is not the current committed installation: \(id)"
        case let .installFailed(reason):
            return "installation failed and was rolled back: \(reason)"
        case let .rollbackFailed(original, rollback):
            return "installation failed (\(original)); rollback also failed (\(rollback))"
        case let .durabilityFailure(path):
            return "could not make installation state durable: \(path)"
        }
    }
}

/// Durable staged replacement of manifest-managed files under one game root.
///
/// Callers may use `install` for the complete operation, or the explicit
/// `prepare`, `stage`, and `commit` phases when command-level progress needs to
/// be reported. Every write after the prepared phase either commits, completes
/// a durable removal, or attempts a verified rollback. recoverAtStartup must
/// run before other command work; prepare also invokes it so a future
/// integration cannot accidentally skip recovery before beginning a new
/// transaction.
public struct InstallationTransactionService {
    public let gameRoot: URL

    private let fileManager: FileManager
    private let stateRootRelative = "archive-loader/state"

    public init(gameRoot: URL, fileManager: FileManager = .default) {
        self.gameRoot = gameRoot.standardizedFileURL
        self.fileManager = fileManager
    }

    public func install(
        manifestDocument: CompatibilityManifestDocument,
        packageRoot: URL,
        verifiedIdentity: CompatibilityIdentity,
        transactionID: String = UUID().uuidString.lowercased(),
        beforeReplacing: (InstallationManagedMapping) throws -> Void = { _ in }
    ) throws -> InstallationTransactionMarker {
        let prepared = try prepare(
            manifestDocument: manifestDocument,
            packageRoot: packageRoot,
            verifiedIdentity: verifiedIdentity,
            transactionID: transactionID
        )
        _ = try stage(transactionID: prepared.transactionID, packageRoot: packageRoot)
        return try commit(transactionID: prepared.transactionID, beforeReplacing: beforeReplacing)
    }

    public func prepare(
        manifestDocument: CompatibilityManifestDocument,
        packageRoot: URL,
        verifiedIdentity: CompatibilityIdentity,
        transactionID: String = UUID().uuidString.lowercased(),
        afterMarkerPublished: () throws -> Void = {}
    ) throws -> InstallationTransactionMarker {
        try validateTransactionID(transactionID)
        _ = try recoverAtStartup()
        try manifestDocument.manifest.validate()
        _ = try CompatibilityPackageValidator.validate(
            manifest: manifestDocument.manifest,
            packageRoot: packageRoot,
            fileManager: fileManager
        )
        try CompatibilityIdentityValidator.requireMatch(
            target: manifestDocument.manifest.target,
            actual: verifiedIdentity
        )

        let markerURL = markerURL(transactionID: transactionID)
        guard !fileManager.fileExists(atPath: markerURL.path) else {
            throw InstallationTransactionError.transactionAlreadyExists(transactionID)
        }

        let mappings = try manifestDocument.manifest.managedFiles.map { entry in
            try validateManagedPath(entry.gamePath)
            return InstallationManagedMapping(
                packagePath: entry.packagePath,
                gamePath: entry.gamePath,
                expectedSHA256: entry.sha256,
                installedSHA256: nil
            )
        }
        let sourceHashes = try mappings.map { mapping in
            let source = packageRoot.standardizedFileURL.appending(path: mapping.packagePath)
            let actual = try managedHash(at: source, mapping: mapping)
            return InstallationSourceHash(
                packagePath: mapping.packagePath,
                expectedSHA256: mapping.expectedSHA256,
                actualSHA256: actual
            )
        }
        let parent = try currentCommittedMarker() ?? generationZeroMarker()
        let generation: UInt64
        if let parent {
            guard parent.generation < UInt64.max else {
                throw InstallationTransactionError.corruptMarker(
                    "installation generation overflow after \(parent.transactionID)"
                )
            }
            generation = parent.generation + 1
        } else {
            generation = 1
        }
        var marker = InstallationTransactionMarker(
            transactionID: transactionID,
            phase: .snapshotting,
            manifestSelfHash: manifestDocument.maskedSelfHash,
            targetIdentity: manifestDocument.manifest.target,
            sourcePackageHashes: sourceHashes,
            snapshotPath: snapshotRelativePath(transactionID),
            stagingPath: stagingRelativePath(transactionID),
            managedMappings: mappings,
            generation: generation,
            parentTransactionID: parent?.transactionID
        )

        try createStateDirectories()
        try writeMarker(marker)
        try afterMarkerPublished()
        try captureSnapshot(for: marker)
        _ = try verifiedSnapshot(for: marker)
        marker.phase = .prepared
        try writeMarker(marker)
        return marker
    }

    public func stage(
        transactionID: String,
        packageRoot: URL
    ) throws -> InstallationTransactionMarker {
        let marker = try marker(transactionID: transactionID)
        try requirePhase(marker, .prepared)

        do {
            _ = try verifiedSnapshot(for: marker)
            let stagingRoot = gameRoot.appending(path: marker.stagingPath)
            guard !fileManager.fileExists(atPath: stagingRoot.path) else {
                throw InstallationTransactionError.stagedFileInvalid(
                    path: marker.stagingPath,
                    reason: "staging directory already exists"
                )
            }
            try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: false)

            for mapping in marker.managedMappings {
                let source = packageRoot.standardizedFileURL.appending(path: mapping.packagePath)
                let actual = try managedHash(at: source, mapping: mapping)
                guard actual == mapping.expectedSHA256 else {
                    throw InstallationTransactionError.stagedFileInvalid(
                        path: mapping.packagePath,
                        reason: "expected \(mapping.expectedSHA256), found \(actual)"
                    )
                }
                let destination = stagedFileURL(marker: marker, gamePath: mapping.gamePath)
                try durableCopy(from: source, to: destination)
                let stagedHash = try managedHash(at: destination, mapping: mapping)
                guard stagedHash == mapping.expectedSHA256 else {
                    throw InstallationTransactionError.stagedFileInvalid(
                        path: mapping.gamePath,
                        reason: "expected \(mapping.expectedSHA256), found \(stagedHash)"
                    )
                }
            }
            try syncDirectory(stagingRoot)
            var staged = marker
            staged.phase = .staged
            try writeMarker(staged)
            return staged
        } catch {
            try failWithRollback(marker: marker, original: error)
        }
    }

    public func commit(
        transactionID: String,
        beforeReplacing: (InstallationManagedMapping) throws -> Void = { _ in }
    ) throws -> InstallationTransactionMarker {
        var marker = try marker(transactionID: transactionID)
        try requirePhase(marker, .staged)

        do {
            _ = try verifiedSnapshot(for: marker)
            try verifyStaging(marker)
            marker.phase = .replacing
            try writeMarker(marker)

            for mapping in marker.managedMappings {
                try beforeReplacing(mapping)
                let source = stagedFileURL(marker: marker, gamePath: mapping.gamePath)
                let destination = gameFileURL(mapping.gamePath)
                try atomicReplace(from: source, to: destination)
            }

            for index in marker.managedMappings.indices {
                let mapping = marker.managedMappings[index]
                let actual = try managedHash(at: gameFileURL(mapping.gamePath), mapping: mapping)
                guard actual == mapping.expectedSHA256 else {
                    throw InstallationTransactionError.installedFileInvalid(
                        path: mapping.gamePath,
                        reason: "expected \(mapping.expectedSHA256), found \(actual)"
                    )
                }
                marker.managedMappings[index].installedSHA256 = actual
            }
            marker.phase = .committed
            try writeMarker(marker)

            // The committed marker is durable before staging is retired. A
            // cleanup failure is harmless and leaves auditable bytes behind.
            try? fileManager.removeItem(at: gameRoot.appending(path: marker.stagingPath))
            return marker
        } catch {
            try failWithRollback(marker: marker, original: error)
        }
    }

    public func rollback(transactionID: String) throws -> InstallationTransactionMarker {
        let marker = try marker(transactionID: transactionID)
        guard marker.phase != .rolledBack else { return marker }
        if marker.phase == .snapshotting {
            return try retireSnapshottingTransaction(marker)
        }
        if marker.phase == .removing {
            return try finishRemoval(marker: marker)
        }
        return try restoreSnapshot(marker: marker)
    }

    /// Removes one current committed installation by restoring its complete
    /// pre-replacement snapshot. The marker remains as a rolled-back audit
    /// record, so the durable transaction marker is still the only commit
    /// record and older committed generations can become current again.
    public func removeCommitted(
        transactionID: String,
        beforeRemoving: (InstallationSnapshotEntry) throws -> Void = { _ in }
    ) throws -> InstallationTransactionMarker {
        _ = try recoverAtStartup()
        if transactionID == "generation-0",
           !fileManager.fileExists(atPath: markerURL(transactionID: transactionID).path) {
            return try removeGenerationZero(beforeRemoving: beforeRemoving)
        }

        let marker = try marker(transactionID: transactionID)
        if marker.phase == .rolledBack {
            return marker
        }
        try requirePhase(marker, .committed)
        try validateCommittedRecord(marker)
        guard try currentCommittedMarker()?.transactionID == transactionID,
              committedContentMatches(marker)
        else {
            throw InstallationTransactionError.transactionNotCurrent(transactionID)
        }
        var removing = marker
        removing.phase = .removing
        try writeMarker(removing)
        return try finishRemoval(marker: removing, beforeMutating: beforeRemoving)
    }

    /// Rolls back active records, resumes durable removals, and verifies only
    /// the current committed record. Snapshot and staging evidence are never
    /// deleted by recovery.
    @discardableResult
    public func recoverAtStartup() throws -> [InstallationTransactionMarker] {
        var recovered: [InstallationTransactionMarker] = []
        for marker in try allMarkers() {
            switch marker.phase {
            case .snapshotting:
                recovered.append(try retireSnapshottingTransaction(marker))
            case .prepared, .staged, .replacing:
                recovered.append(try rollback(transactionID: marker.transactionID))
            case .removing:
                recovered.append(try finishRemoval(marker: marker))
            case .committed:
                break
            case .rolledBack:
                break
            }
        }
        _ = try verifyCommittedTransactions()
        return recovered
    }

    public func verifyCommittedTransactions() throws -> [InstallationTransactionMarker] {
        guard let current = try currentCommittedMarker() else {
            return []
        }
        guard committedContentMatches(current) else {
            throw InstallationTransactionError.installedFileInvalid(
                path: "committed transaction set",
                reason: "installed content does not match the current committed record"
            )
        }
        return [current]
    }

    /// Inspects durable records without changing them. If no transaction
    /// marker exists, an installed compatibility manifest is exposed as an
    /// in-memory generation-zero record for migration and status consumers.
    /// It is deliberately not persisted and never creates an active link.
    public func inspect() throws -> InstallationTransactionInspection {
        let markers = try allMarkers()
        let committed = markers.filter { $0.phase == .committed }
        let interrupted = markers.filter {
            $0.phase == .snapshotting
                || $0.phase == .prepared
                || $0.phase == .staged
                || $0.phase == .replacing
                || $0.phase == .removing
        }
        let rolledBack = markers.filter { $0.phase == .rolledBack }

        let currentCommitted = try currentCommittedMarker()
        if interrupted.isEmpty,
           let currentCommitted,
           !committedContentMatches(currentCommitted) {
            throw InstallationTransactionError.installedFileInvalid(
                path: "committed transaction",
                reason: "installed content does not match the current committed record"
            )
        }

        let generationZero: InstallationTransactionMarker?
        if committed.isEmpty && interrupted.isEmpty {
            generationZero = try generationZeroMarker()
        } else {
            generationZero = nil
        }
        let current = interrupted.isEmpty ? (currentCommitted ?? generationZero) : nil
        return InstallationTransactionInspection(
            committed: committed,
            interrupted: interrupted,
            rolledBack: rolledBack,
            generationZero: generationZero,
            current: current
        )
    }

    private func restoreSnapshot(
        marker: InstallationTransactionMarker,
        beforeMutating: (InstallationSnapshotEntry) throws -> Void = { _ in }
    ) throws -> InstallationTransactionMarker {
        let snapshot = try verifiedSnapshot(for: marker)

        for entry in snapshot.entries {
            try beforeMutating(entry)
            let destination = gameFileURL(entry.gamePath)
            if entry.wasPresent {
                let source = snapshotFileURL(marker: marker, gamePath: entry.gamePath)
                try atomicReplace(from: source, to: destination)
                guard let mode = entry.mode, chmod(destination.path, mode_t(mode)) == 0 else {
                    throw InstallationTransactionError.snapshotInvalid(
                        id: marker.transactionID,
                        reason: "could not restore mode for \(entry.gamePath)"
                    )
                }
                try syncFile(destination)
            } else if fileManager.fileExists(atPath: destination.path) {
                let attributes = try fileManager.attributesOfItem(atPath: destination.path)
                guard attributes[.type] as? FileAttributeType != .typeDirectory else {
                    throw InstallationTransactionError.snapshotInvalid(
                        id: marker.transactionID,
                        reason: "refusing to remove directory at absent managed path \(entry.gamePath)"
                    )
                }
                try fileManager.removeItem(at: destination)
                try syncDirectory(destination.deletingLastPathComponent())
            }
        }

        try verifyRestored(snapshot: snapshot)
        var completed = marker
        completed.phase = .rolledBack
        try writeMarker(completed)
        return completed
    }

    private func retireSnapshottingTransaction(
        _ marker: InstallationTransactionMarker
    ) throws -> InstallationTransactionMarker {
        for relativePath in [marker.snapshotPath, marker.stagingPath] {
            let path = gameRoot.appending(path: relativePath)
            guard fileManager.fileExists(atPath: path.path) else { continue }
            try fileManager.removeItem(at: path)
            let parent = path.deletingLastPathComponent()
            if fileManager.fileExists(atPath: parent.path) {
                try syncDirectory(parent)
            }
        }
        var retired = marker
        retired.phase = .rolledBack
        try writeMarker(retired)
        return retired
    }

    private func finishRemoval(
        marker: InstallationTransactionMarker,
        beforeMutating: (InstallationSnapshotEntry) throws -> Void = { _ in }
    ) throws -> InstallationTransactionMarker {
        if marker.transactionID == "generation-0",
           !fileManager.fileExists(atPath: snapshotManifestURL(marker).path) {
            try captureRemovalSnapshot(for: marker)
        }
        return try restoreSnapshot(marker: marker, beforeMutating: beforeMutating)
    }

    private func removeGenerationZero(
        beforeRemoving: (InstallationSnapshotEntry) throws -> Void
    ) throws -> InstallationTransactionMarker {
        guard let legacy = try generationZeroMarker() else {
            throw InstallationTransactionError.transactionNotCurrent("generation-0")
        }
        var removing = legacy
        removing.phase = .removing
        try writeMarker(removing)
        try captureRemovalSnapshot(for: removing)
        return try finishRemoval(marker: removing, beforeMutating: beforeRemoving)
    }

    public func marker(transactionID: String) throws -> InstallationTransactionMarker {
        try validateTransactionID(transactionID)
        let url = markerURL(transactionID: transactionID)
        guard fileManager.fileExists(atPath: url.path) else {
            throw InstallationTransactionError.transactionNotFound(transactionID)
        }
        do {
            let decoded = try JSONDecoder().decode(
                InstallationTransactionMarker.self,
                from: Data(contentsOf: url)
            )
            try validateMarker(decoded, expectedID: transactionID)
            return decoded
        } catch let error as InstallationTransactionError {
            throw error
        } catch {
            throw InstallationTransactionError.corruptMarker("\(url.path): \(error)")
        }
    }

    public func snapshot(transactionID: String) throws -> InstallationSnapshot {
        let marker = try marker(transactionID: transactionID)
        let url = snapshotManifestURL(marker)
        do {
            return try JSONDecoder().decode(InstallationSnapshot.self, from: Data(contentsOf: url))
        } catch {
            throw InstallationTransactionError.snapshotInvalid(
                id: transactionID,
                reason: "snapshot manifest is missing or malformed: \(error)"
            )
        }
    }

    public func markerURL(transactionID: String) -> URL {
        gameRoot.appending(path: transactionsRelativeDirectory)
            .appending(path: "\(transactionID).json")
    }

    private var transactionsRelativeDirectory: String {
        "\(stateRootRelative)/install-transactions"
    }

    private func snapshotRelativePath(_ id: String) -> String {
        "\(stateRootRelative)/install-snapshots/\(id)"
    }

    private func stagingRelativePath(_ id: String) -> String {
        "\(stateRootRelative)/install-staging/\(id)"
    }

    private func createStateDirectories() throws {
        for path in [
            transactionsRelativeDirectory,
            "\(stateRootRelative)/install-snapshots",
            "\(stateRootRelative)/install-staging",
        ] {
            try fileManager.createDirectory(
                at: gameRoot.appending(path: path),
                withIntermediateDirectories: true
            )
        }
    }

    private func captureSnapshot(for marker: InstallationTransactionMarker) throws {
        let root = gameRoot.appending(path: marker.snapshotPath)
        guard !fileManager.fileExists(atPath: root.path) else {
            throw InstallationTransactionError.snapshotInvalid(
                id: marker.transactionID,
                reason: "snapshot directory already exists"
            )
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)

        var entries: [InstallationSnapshotEntry] = []
        for mapping in marker.managedMappings {
            let source = gameFileURL(mapping.gamePath)
            if fileManager.fileExists(atPath: source.path) {
                let attributes = try regularFileAttributes(source, managedPath: mapping.gamePath)
                let mode = UInt16(truncating: (attributes[.posixPermissions] as? NSNumber) ?? 0)
                let hash = try Hashes.sha256Hex(ofFileAt: source)
                try durableCopy(
                    from: source,
                    to: snapshotFileURL(marker: marker, gamePath: mapping.gamePath)
                )
                entries.append(InstallationSnapshotEntry(
                    gamePath: mapping.gamePath,
                    wasPresent: true,
                    mode: mode,
                    sha256: hash
                ))
            } else {
                entries.append(InstallationSnapshotEntry(
                    gamePath: mapping.gamePath,
                    wasPresent: false,
                    mode: nil,
                    sha256: nil
                ))
            }
        }

        let snapshot = InstallationSnapshot(
            transactionID: marker.transactionID,
            manifestSelfHash: marker.manifestSelfHash,
            targetIdentity: marker.targetIdentity,
            entries: entries,
            complete: true
        )
        try durableWrite(try JSONEncoder.pretty.encode(snapshot), to: snapshotManifestURL(marker))
        try syncDirectory(root)
    }

    /// Generation zero has no pre-install snapshot to restore. Its explicit
    /// removal record therefore uses an all-absent target snapshot: removal
    /// deletes only the verified compatibility mappings and is idempotently
    /// resumable from the durable removing marker.
    private func captureRemovalSnapshot(for marker: InstallationTransactionMarker) throws {
        let root = gameRoot.appending(path: marker.snapshotPath)
        if !fileManager.fileExists(atPath: root.path) {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        }
        let entries = marker.managedMappings.map { mapping in
            InstallationSnapshotEntry(
                gamePath: mapping.gamePath,
                wasPresent: false,
                mode: nil,
                sha256: nil
            )
        }
        let snapshot = InstallationSnapshot(
            transactionID: marker.transactionID,
            manifestSelfHash: marker.manifestSelfHash,
            targetIdentity: marker.targetIdentity,
            entries: entries,
            complete: true
        )
        try durableWrite(try JSONEncoder.pretty.encode(snapshot), to: snapshotManifestURL(marker))
        try syncDirectory(root)
    }

    private func verifiedSnapshot(for marker: InstallationTransactionMarker) throws -> InstallationSnapshot {
        let value = try snapshot(transactionID: marker.transactionID)
        guard value.complete,
              value.transactionID == marker.transactionID,
              value.manifestSelfHash == marker.manifestSelfHash,
              value.targetIdentity == marker.targetIdentity,
              value.entries.map(\.gamePath) == marker.managedMappings.map(\.gamePath)
        else {
            throw InstallationTransactionError.snapshotInvalid(
                id: marker.transactionID,
                reason: "snapshot identity or managed mapping is incomplete"
            )
        }
        for entry in value.entries where entry.wasPresent {
            guard let expectedHash = entry.sha256, entry.mode != nil else {
                throw InstallationTransactionError.snapshotInvalid(
                    id: marker.transactionID,
                    reason: "present entry \(entry.gamePath) lacks hash or mode"
                )
            }
            let source = snapshotFileURL(marker: marker, gamePath: entry.gamePath)
            let actual = try regularFileHash(source, managedPath: entry.gamePath)
            guard actual == expectedHash else {
                throw InstallationTransactionError.snapshotInvalid(
                    id: marker.transactionID,
                    reason: "\(entry.gamePath) expected \(expectedHash), found \(actual)"
                )
            }
        }
        for entry in value.entries where !entry.wasPresent {
            guard entry.sha256 == nil, entry.mode == nil else {
                throw InstallationTransactionError.snapshotInvalid(
                    id: marker.transactionID,
                    reason: "absent entry \(entry.gamePath) contains file metadata"
                )
            }
        }
        return value
    }

    private func verifyStaging(_ marker: InstallationTransactionMarker) throws {
        for mapping in marker.managedMappings {
            let source = stagedFileURL(marker: marker, gamePath: mapping.gamePath)
            let actual = try managedHash(at: source, mapping: mapping)
            guard actual == mapping.expectedSHA256 else {
                throw InstallationTransactionError.stagedFileInvalid(
                    path: mapping.gamePath,
                    reason: "expected \(mapping.expectedSHA256), found \(actual)"
                )
            }
        }
    }

    private func validateCommittedRecord(_ marker: InstallationTransactionMarker) throws {
        _ = try verifiedSnapshot(for: marker)
        for mapping in marker.managedMappings {
            guard mapping.installedSHA256 == mapping.expectedSHA256 else {
                throw InstallationTransactionError.corruptMarker(
                    "committed mapping \(mapping.gamePath) lacks its installed hash"
                )
            }
        }
    }

    private func committedContentMatches(_ marker: InstallationTransactionMarker) -> Bool {
        for mapping in marker.managedMappings {
            guard let actual = try? managedHash(at: gameFileURL(mapping.gamePath), mapping: mapping),
                  actual == mapping.installedSHA256
            else { return false }
        }
        return true
    }

    private func verifyRestored(snapshot: InstallationSnapshot) throws {
        for entry in snapshot.entries {
            let destination = gameFileURL(entry.gamePath)
            if entry.wasPresent {
                guard let expectedHash = entry.sha256, let expectedMode = entry.mode else {
                    throw InstallationTransactionError.snapshotInvalid(
                        id: snapshot.transactionID,
                        reason: "present entry \(entry.gamePath) lacks hash or mode"
                    )
                }
                let attributes = try regularFileAttributes(destination, managedPath: entry.gamePath)
                let actualHash = try Hashes.sha256Hex(ofFileAt: destination)
                let actualMode = UInt16(truncating: (attributes[.posixPermissions] as? NSNumber) ?? 0)
                guard actualHash == expectedHash, actualMode == expectedMode else {
                    throw InstallationTransactionError.snapshotInvalid(
                        id: snapshot.transactionID,
                        reason: "restored file \(entry.gamePath) does not match its bytes and mode"
                    )
                }
            } else if fileManager.fileExists(atPath: destination.path) {
                throw InstallationTransactionError.snapshotInvalid(
                    id: snapshot.transactionID,
                    reason: "absent path \(entry.gamePath) still exists after rollback"
                )
            }
        }
    }

    private func allMarkers() throws -> [InstallationTransactionMarker] {
        let directory = gameRoot.appending(path: transactionsRelativeDirectory)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let names = try fileManager.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") }
            .sorted()
        return try names.map { name in
            let id = String(name.dropLast(5))
            return try marker(transactionID: id)
        }
    }

    /// Selects the one committed leaf in the durable transaction lineage.
    /// Legacy markers decode as generation zero without a parent; multiple
    /// such roots are intentionally ambiguous and fail closed.
    private func currentCommittedMarker() throws -> InstallationTransactionMarker? {
        let committed = try allMarkers().filter { $0.phase == .committed }
        guard !committed.isEmpty else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: committed.map { ($0.transactionID, $0) })

        for marker in committed {
            try validateCommittedRecord(marker)
            if let parentID = marker.parentTransactionID {
                if parentID == "generation-0" {
                    guard marker.generation == 1 else {
                        throw InstallationTransactionError.corruptMarker(
                            "generation-zero parent must have generation one"
                        )
                    }
                    continue
                }
                guard let parent = byID[parentID],
                      parentID != marker.transactionID,
                      parent.generation < UInt64.max,
                      marker.generation == parent.generation + 1
                else {
                    throw InstallationTransactionError.corruptMarker(
                        "committed transaction \(marker.transactionID) has an invalid lineage parent"
                    )
                }
            } else if marker.generation > 1 {
                throw InstallationTransactionError.corruptMarker(
                    "generation \(marker.generation) has no lineage parent"
                )
            }
        }

        let parentIDs = Set(committed.compactMap(\.parentTransactionID))
        let leaves = committed.filter { !parentIDs.contains($0.transactionID) }
        if leaves.count == 1, let current = leaves.first {
            return current
        }

        guard leaves.allSatisfy({ $0.isLegacyLineage }) else {
            throw InstallationTransactionError.corruptMarker(
                "committed transaction lineage is ambiguous: multiple non-legacy leaves"
            )
        }

        let matchingLeaves = leaves.filter { committedContentMatches($0) }
        guard matchingLeaves.count == 1, let current = matchingLeaves.first else {
            let matchingIDs = matchingLeaves.map(\.transactionID).joined(separator: ", ")
            let matchDescription = matchingLeaves.isEmpty
                ? "no leaf matches live content"
                : "multiple leaves match live content: \(matchingIDs)"
            throw InstallationTransactionError.corruptMarker(
                "committed transaction lineage is ambiguous: \(matchDescription)"
            )
        }
        return current
    }

    private func generationZeroMarker() throws -> InstallationTransactionMarker? {
        let manifestURL = gameRoot.appending(path: "archive-loader/compatibility/manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else { return nil }

        let document: CompatibilityManifestDocument
        do {
            document = try CompatibilityManifestDocument(bytes: Data(contentsOf: manifestURL))
        } catch {
            throw InstallationTransactionError.corruptMarker(
                "generation-zero compatibility marker is invalid: \(error)"
            )
        }

        var mappings: [InstallationManagedMapping] = []
        var sourceHashes: [InstallationSourceHash] = []
        for entry in document.manifest.managedFiles {
            try validateManagedPath(entry.gamePath)
            let mapping = InstallationManagedMapping(
                packagePath: entry.packagePath,
                gamePath: entry.gamePath,
                expectedSHA256: entry.sha256,
                installedSHA256: nil
            )
            let actual: String
            do {
                actual = try managedHash(at: gameFileURL(entry.gamePath), mapping: mapping)
            } catch {
                throw InstallationTransactionError.installedFileInvalid(
                    path: entry.gamePath,
                    reason: "generation-zero compatibility marker is incomplete: \(error)"
                )
            }
            guard actual == entry.sha256 else {
                throw InstallationTransactionError.installedFileInvalid(
                    path: entry.gamePath,
                    reason: "generation-zero compatibility marker expected \(entry.sha256), found \(actual)"
                )
            }
            var installed = mapping
            installed.installedSHA256 = actual
            mappings.append(installed)
            sourceHashes.append(InstallationSourceHash(
                packagePath: entry.packagePath,
                expectedSHA256: entry.sha256,
                actualSHA256: actual
            ))
        }

        return InstallationTransactionMarker(
            transactionID: "generation-0",
            phase: .committed,
            manifestSelfHash: document.maskedSelfHash,
            targetIdentity: document.manifest.target,
            sourcePackageHashes: sourceHashes,
            snapshotPath: snapshotRelativePath("generation-0"),
            stagingPath: stagingRelativePath("generation-0"),
            managedMappings: mappings
        )
    }

    private func validateMarker(_ marker: InstallationTransactionMarker, expectedID: String) throws {
        guard marker.transactionID == expectedID else {
            throw InstallationTransactionError.corruptMarker("filename and transaction id disagree")
        }
        guard marker.snapshotPath == snapshotRelativePath(expectedID),
              marker.stagingPath == stagingRelativePath(expectedID),
              isSHA256(marker.manifestSelfHash),
              !marker.managedMappings.isEmpty,
              marker.sourcePackageHashes.count == marker.managedMappings.count,
              marker.generation == 0 ? marker.parentTransactionID == nil : true
        else {
            throw InstallationTransactionError.corruptMarker("paths, manifest hash, or mappings are incomplete")
        }
        if let parentTransactionID = marker.parentTransactionID {
            try validateTransactionID(parentTransactionID)
            guard parentTransactionID != marker.transactionID else {
                throw InstallationTransactionError.corruptMarker("transaction cannot be its own lineage parent")
            }
        }
        let sourcePaths = marker.sourcePackageHashes.map(\.packagePath)
        guard sourcePaths == marker.managedMappings.map(\.packagePath) else {
            throw InstallationTransactionError.corruptMarker("source hash results do not match managed mappings")
        }
        for (source, mapping) in zip(marker.sourcePackageHashes, marker.managedMappings) {
            try validateManagedPath(mapping.gamePath)
            guard source.expectedSHA256 == mapping.expectedSHA256,
                  source.actualSHA256 == mapping.expectedSHA256,
                  isSHA256(mapping.expectedSHA256)
            else {
                throw InstallationTransactionError.corruptMarker("source hash result is invalid for \(mapping.packagePath)")
            }
        }
    }

    private func validateTransactionID(_ id: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !id.isEmpty,
              id.utf8.count <= 128,
              id != ".",
              id != "..",
              id.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else {
            throw InstallationTransactionError.invalidTransactionID(id)
        }
    }

    private func validateManagedPath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("./"),
              !path.contains("\\"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !path.hasPrefix("\(stateRootRelative)/install-")
        else {
            throw InstallationTransactionError.invalidManagedFile(
                path: path,
                reason: "path is not a safe game-root-relative managed file"
            )
        }
    }

    private func requirePhase(
        _ marker: InstallationTransactionMarker,
        _ expected: InstallationTransactionPhase
    ) throws {
        guard marker.phase == expected else {
            throw InstallationTransactionError.invalidTransition(
                id: marker.transactionID,
                expected: expected,
                actual: marker.phase
            )
        }
    }

    private func failWithRollback(
        marker: InstallationTransactionMarker,
        original: Error
    ) throws -> Never {
        do {
            _ = try rollback(transactionID: marker.transactionID)
            throw InstallationTransactionError.installFailed(String(describing: original))
        } catch let rollbackError as InstallationTransactionError {
            if case .installFailed = rollbackError { throw rollbackError }
            throw InstallationTransactionError.rollbackFailed(
                original: String(describing: original),
                rollback: String(describing: rollbackError)
            )
        } catch {
            throw InstallationTransactionError.rollbackFailed(
                original: String(describing: original),
                rollback: String(describing: error)
            )
        }
    }

    private func gameFileURL(_ gamePath: String) -> URL {
        gameRoot.appending(path: gamePath)
    }

    private func stagedFileURL(marker: InstallationTransactionMarker, gamePath: String) -> URL {
        gameRoot.appending(path: marker.stagingPath).appending(path: "files/\(gamePath)")
    }

    private func snapshotFileURL(marker: InstallationTransactionMarker, gamePath: String) -> URL {
        gameRoot.appending(path: marker.snapshotPath).appending(path: "files/\(gamePath)")
    }

    private func snapshotManifestURL(_ marker: InstallationTransactionMarker) -> URL {
        gameRoot.appending(path: marker.snapshotPath).appending(path: "snapshot.json")
    }

    private func managedHash(at url: URL, mapping: InstallationManagedMapping) throws -> String {
        _ = try regularFileAttributes(url, managedPath: mapping.gamePath)
        if mapping.packagePath == "archive-loader/compatibility/manifest.json",
           mapping.gamePath == "archive-loader/compatibility/manifest.json" {
            do {
                return try CompatibilityManifestDocument(bytes: Data(contentsOf: url)).maskedSelfHash
            } catch {
                throw InstallationTransactionError.invalidManagedFile(
                    path: mapping.gamePath,
                    reason: "manifest self-hash validation failed: \(error)"
                )
            }
        }
        return try Hashes.sha256Hex(ofFileAt: url)
    }

    private func regularFileHash(_ url: URL, managedPath: String) throws -> String {
        _ = try regularFileAttributes(url, managedPath: managedPath)
        return try Hashes.sha256Hex(ofFileAt: url)
    }

    private func regularFileAttributes(_ url: URL, managedPath: String) throws -> [FileAttributeKey: Any] {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw InstallationTransactionError.invalidManagedFile(
                    path: managedPath,
                    reason: "expected a regular file"
                )
            }
            return attributes
        } catch let error as InstallationTransactionError {
            throw error
        } catch {
            throw InstallationTransactionError.invalidManagedFile(
                path: managedPath,
                reason: "missing or unreadable: \(error)"
            )
        }
    }

    private func writeMarker(_ marker: InstallationTransactionMarker) throws {
        try validateMarker(marker, expectedID: marker.transactionID)
        try durableWrite(try JSONEncoder.pretty.encode(marker), to: markerURL(transactionID: marker.transactionID))
    }

    private func durableCopy(from source: URL, to destination: URL) throws {
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw InstallationTransactionError.invalidManagedFile(
                path: destination.path,
                reason: "destination already exists"
            )
        }
        try fileManager.copyItem(at: source, to: destination)
        try syncFile(destination)
        try syncDirectory(destination.deletingLastPathComponent())
    }

    private func atomicReplace(from source: URL, to destination: URL) throws {
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporary = destination.deletingLastPathComponent()
            .appending(path: ".archive-loader-install-\(UUID().uuidString).tmp")
        do {
            try fileManager.copyItem(at: source, to: temporary)
            try syncFile(temporary)
            let result = temporary.withUnsafeFileSystemRepresentation { temporaryPath -> Int32 in
                guard let temporaryPath else { return -1 }
                return destination.withUnsafeFileSystemRepresentation { destinationPath -> Int32 in
                    guard let destinationPath else { return -1 }
                    return Darwin.rename(temporaryPath, destinationPath)
                }
            }
            guard result == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try syncDirectory(destination.deletingLastPathComponent())
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private func durableWrite(_ data: Data, to destination: URL) throws {
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporary = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary)
            try syncFile(temporary)
            let result = temporary.withUnsafeFileSystemRepresentation { temporaryPath -> Int32 in
                guard let temporaryPath else { return -1 }
                return destination.withUnsafeFileSystemRepresentation { destinationPath -> Int32 in
                    guard let destinationPath else { return -1 }
                    return Darwin.rename(temporaryPath, destinationPath)
                }
            }
            guard result == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try syncDirectory(destination.deletingLastPathComponent())
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private func syncFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw InstallationTransactionError.durabilityFailure(url.path)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw InstallationTransactionError.durabilityFailure(url.path)
        }
    }

    private func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw InstallationTransactionError.durabilityFailure(url.path)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw InstallationTransactionError.durabilityFailure(url.path)
        }
    }
}

private func isSHA256(_ value: String) -> Bool {
    value.utf8.count == 64 && value.unicodeScalars.allSatisfy { scalar in
        (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 97 && scalar.value <= 102)
    }
}
