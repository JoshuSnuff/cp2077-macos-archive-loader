import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum FrameworkProjectionKind: String, Sendable, Equatable {
    case tweak
    case archive
}

public struct FrameworkModProjectionEntry: Sendable, Equatable {
    public let source: URL
    public let destination: URL
    public let kind: FrameworkProjectionKind
    public let sha256: String
    public let sourceRoot: URL
    public let sourceRole: ModFrameworkSourceRole
    public let relativeSourcePath: String
    public let ownershipToken: String

    public init(
        source: URL,
        destination: URL,
        kind: FrameworkProjectionKind,
        sha256: String,
        sourceRoot: URL? = nil,
        sourceRole: ModFrameworkSourceRole = .archivePayload,
        relativeSourcePath: String? = nil,
        ownershipToken: String? = nil
    ) {
        self.source = source
        self.destination = destination
        self.kind = kind
        self.sha256 = sha256
        self.sourceRoot = (sourceRoot ?? source.deletingLastPathComponent()).standardizedFileURL
        self.sourceRole = sourceRole
        self.relativeSourcePath = relativeSourcePath ?? source.lastPathComponent
        self.ownershipToken = ownershipToken ?? destination.lastPathComponent
    }
}

private struct DurableProjectionEntry: Codable, Sendable, Equatable {
    let sourcePath: String
    let destinationPath: String
    let kind: String
    let sha256: String
    let sourceRootPath: String
    let sourceRole: String
    let relativeSourcePath: String
    let ownershipToken: String
}

private struct DurableProjectionRecord: Codable, Sendable, Equatable {
    let schema: String
    let sessionID: String
    let entries: [DurableProjectionEntry]
}

public enum FrameworkModProjectionError: Error, CustomStringConvertible, Equatable {
    case sourceIsSymlink(URL)
    case sourceIsNotRegular(URL)
    case sourceOutsideExpectedRoot(URL, URL)
    case sourceAncestorIsSymlink(URL)
    case destinationIsUnsafe(URL)
    case destinationExists(URL)
    case destinationHashMismatch(URL)
    case destinationOwnershipMismatch(URL)
    case destinationIsNotRegular(URL)
    case projectionRootIsSymlink(URL)
    case durableRecordMalformed(URL, String)
    case durabilityFailure(URL)

    public var description: String {
        switch self {
        case let .sourceIsSymlink(url): return "framework source is a symlink: \(url.path)"
        case let .sourceIsNotRegular(url): return "framework source is not a regular file: \(url.path)"
        case let .sourceOutsideExpectedRoot(url, root):
            return "framework source \(url.path) is outside \(root.path)"
        case let .sourceAncestorIsSymlink(url):
            return "framework source has a symlinked ancestor: \(url.path)"
        case let .destinationIsUnsafe(url): return "framework projection path is unsafe: \(url.path)"
        case let .destinationExists(url): return "framework projection destination already exists: \(url.path)"
        case let .destinationHashMismatch(url):
            return "framework projection changed after staging: \(url.path)"
        case let .destinationOwnershipMismatch(url):
            return "framework projection is not owned by this session: \(url.path)"
        case let .destinationIsNotRegular(url):
            return "framework projection is not a regular file: \(url.path)"
        case let .projectionRootIsSymlink(url):
            return "framework projection root is a symlink: \(url.path)"
        case let .durableRecordMalformed(url, detail):
            return "framework projection record is malformed at \(url.path): \(detail)"
        case let .durabilityFailure(url):
            return "framework projection durability failed at \(url.path)"
        }
    }
}

/// Session-scoped copies in the two paths native TweakXL and ArchiveXL scan.
/// The durable state record is the recovery authority; the in-memory registry
/// is only an optimization for the normal in-process cleanup path.
public struct FrameworkModProjection: Sendable, Equatable {
    public static let destinationPrefix = "archive-loader-"
    private static let recordFileName = "framework-projection.json"

    public let entries: [FrameworkModProjectionEntry]

    public init(entries: [FrameworkModProjectionEntry]) {
        self.entries = entries.sorted { utf8Precedes($0.destination.path, $1.destination.path) }
    }

    public var destinations: [URL] { entries.map(\.destination) }
    public var runtimeTweaks: [URL] {
        entries.filter { $0.kind == .tweak }.map(\.source)
    }
    public var archiveResources: [URL] {
        entries.filter { $0.kind == .archive }.map(\.source)
    }
    public var fingerprintInputs: [String] {
        entries.map {
            let root = $0.kind == .tweak ? "r6/tweaks" : "archive/Mac/mod"
            return "\(root)/\($0.destination.lastPathComponent) \($0.sha256)"
        }
    }

    public static func recordURL(game: GameInstall) -> URL {
        game.stateDirectory.appending(path: recordFileName, directoryHint: .notDirectory)
    }

    public static func durableRecord(game: GameInstall) throws -> FrameworkModProjection? {
        guard let record = try readRecord(game: game) else { return nil }
        return FrameworkModProjection(entries: try entries(from: record, game: game))
    }

    public static func stage(
        requirements: ModFrameworkRequirements,
        game: GameInstall
    ) throws -> FrameworkModProjection {
        let manager = FileManager.default
        let gameRoot = game.root.standardizedFileURL
        let tweakRoot = gameRoot.appending(path: "r6/tweaks", directoryHint: .isDirectory)
        let archiveRoot = gameRoot.appending(path: "archive/Mac/mod", directoryHint: .isDirectory)
        try reconcileDurableProjection(game: game)
        try validateGameRoot(gameRoot, manager: manager)
        try prepareDirectory(tweakRoot, gameRoot: gameRoot)
        try prepareDirectory(archiveRoot, gameRoot: gameRoot)

        var created: [URL] = []
        do {
            var staged: [FrameworkModProjectionEntry] = []
            for classification in requirements.classifications {
                switch classification.sourceRole {
                case .tweakDocument:
                    guard !classification.isOpaque, classification.isRuntimeOwned else { continue }
                    try validateSource(
                        classification.mod,
                        role: classification.sourceRole,
                        game: game,
                        sourceRoot: classification.sourceRoot
                    )
                    let relative = relativePath(
                        classification.mod,
                        from: classification.sourceRoot
                    )
                    let stem = projectionStem(
                        sourceRoot: classification.sourceRoot,
                        relativePath: relative,
                        fileName: classification.mod.lastPathComponent
                    )
                    staged.append(try makeEntry(
                        classification.mod,
                        destinationRoot: tweakRoot,
                        kind: .tweak,
                        sourceRoot: classification.sourceRoot,
                        sourceRole: classification.sourceRole,
                        relativeSourcePath: relative,
                        destinationName: stem,
                        gameRoot: gameRoot,
                        manager: manager
                    ))

                case .archivePayload:
                    guard classification.isOpaque,
                          classification.requirements.contains(.archiveXL)
                    else { continue }
                    try validateSource(
                        classification.mod,
                        role: classification.sourceRole,
                        game: game,
                        sourceRoot: classification.sourceRoot
                    )
                    let relative = relativePath(
                        classification.mod,
                        from: classification.sourceRoot
                    )
                    let stem = projectionStem(
                        sourceRoot: classification.sourceRoot,
                        relativePath: relative,
                        fileName: classification.mod.lastPathComponent
                    )
                    staged.append(try makeEntry(
                        classification.mod,
                        destinationRoot: archiveRoot,
                        kind: .archive,
                        sourceRoot: classification.sourceRoot,
                        sourceRole: classification.sourceRole,
                        relativeSourcePath: relative,
                        destinationName: stem,
                        gameRoot: gameRoot,
                        manager: manager
                    ))
                    for associated in classification.associatedFiles {
                        try validateSource(
                            associated,
                            role: classification.sourceRole,
                            game: game,
                            sourceRoot: classification.sourceRoot
                        )
                        let associatedRelative = relativePath(
                            associated,
                            from: classification.sourceRoot
                        )
                        let suffix = associated.lastPathComponent.hasPrefix(
                            classification.mod.lastPathComponent
                        )
                            ? String(associated.lastPathComponent.dropFirst(
                                classification.mod.lastPathComponent.count
                            ))
                            : "-" + associated.lastPathComponent
                        staged.append(try makeEntry(
                            associated,
                            destinationRoot: archiveRoot,
                            kind: .archive,
                            sourceRoot: classification.sourceRoot,
                            sourceRole: classification.sourceRole,
                            relativeSourcePath: associatedRelative,
                            destinationName: stem + suffix,
                            gameRoot: gameRoot,
                            manager: manager
                        ))
                    }
                }
            }
            let projection = FrameworkModProjection(entries: staged)
            guard !projection.entries.isEmpty else {
                try clearRecord(game: game)
                SessionProjectionRegistry.shared.record([], for: gameRoot)
                return projection
            }
            try writeRecord(projection.entries, game: game)
            for entry in projection.entries {
                try copy(entry, manager: manager, created: &created)
            }
            SessionProjectionRegistry.shared.record(projection.entries, for: gameRoot)
            return projection
        } catch {
            var cleanupError: Error?
            for destination in created {
                do {
                    try manager.removeItem(at: destination)
                } catch {
                    cleanupError = cleanupError ?? error
                }
            }
            if cleanupError == nil {
                do {
                    try clearRecord(game: game)
                } catch {
                    cleanupError = error
                }
            }
            if let cleanupError {
                throw cleanupError
            }
            throw error
        }
    }

    public func restore(game: GameInstall) throws -> [URL] {
        let removed = try Self.remove(entries: entries, game: game)
        try Self.clearRecord(game: game)
        SessionProjectionRegistry.shared.clear(entries, for: game.root.standardizedFileURL)
        return removed
    }

    @discardableResult
    public static func restore(game: GameInstall) throws -> [URL] {
        try restore(game: game, removeItem: defaultRemoveItem)
    }

    @discardableResult
    public static func restore(
        game: GameInstall,
        removeItem: @escaping @Sendable (URL) throws -> Void
    ) throws -> [URL] {
        let root = game.root.standardizedFileURL
        let inMemory = SessionProjectionRegistry.shared.entries(for: root)
        let hasDurableRecord = FileManager.default.fileExists(atPath: recordURL(game: game).path)
        let lock = hasDurableRecord && inMemory.isEmpty
            ? try acquireRecoveryLock(game: game)
            : nil
        defer { lock?.release() }
        let durable = try durableRecord(game: game)
        let entries = durable?.entries ?? inMemory
        guard !entries.isEmpty else {
            try clearRecord(game: game)
            return []
        }
        let removed = try remove(entries: entries, game: game, removeItem: removeItem)
        try clearRecord(game: game)
        SessionProjectionRegistry.shared.clear(entries, for: root)
        return removed
    }

    /// Reconciles the durable record as a fresh process would after a crash.
    /// The lock is acquired here because this entry point is intended for
    /// startup/restore recovery rather than a caller already holding it.
    @discardableResult
    public static func reconcile(game: GameInstall) throws -> [URL] {
        try reconcile(game: game, removeItem: defaultRemoveItem)
    }

    @discardableResult
    public static func reconcile(
        game: GameInstall,
        removeItem: @escaping @Sendable (URL) throws -> Void
    ) throws -> [URL] {
        let lock = try acquireRecoveryLock(game: game)
        defer { lock?.release() }
        guard let durable = try durableRecord(game: game), !durable.entries.isEmpty else {
            try clearRecord(game: game)
            return []
        }
        let removed = try remove(entries: durable.entries, game: game, removeItem: removeItem)
        try clearRecord(game: game)
        SessionProjectionRegistry.shared.clear(durable.entries, for: game.root.standardizedFileURL)
        return removed
    }

    private static func remove(
        entries: [FrameworkModProjectionEntry],
        game: GameInstall,
        removeItem: @Sendable (URL) throws -> Void = defaultRemoveItem
    ) throws -> [URL] {
        let gameRoot = game.root.standardizedFileURL
        try validateGameRoot(gameRoot, manager: .default)
        var destinations = Set<String>()
        for entry in entries {
            guard destinations.insert(entry.destination.standardizedFileURL.path).inserted,
                  entry.destination.lastPathComponent == entry.ownershipToken,
                  entry.destination.lastPathComponent.hasPrefix(destinationPrefix)
            else {
                throw FrameworkModProjectionError.destinationOwnershipMismatch(entry.destination)
            }
            try validateDestination(entry.destination, kind: entry.kind, gameRoot: gameRoot)
            guard FileManager.default.fileExists(atPath: entry.destination.path) else { continue }
            let values = try entry.destination.resourceValues(
                forKeys: [.isSymbolicLinkKey, .isRegularFileKey]
            )
            guard !isSymbolicLink(entry.destination), values.isSymbolicLink != true else {
                throw FrameworkModProjectionError.destinationIsUnsafe(entry.destination)
            }
            guard values.isRegularFile == true else {
                throw FrameworkModProjectionError.destinationIsNotRegular(entry.destination)
            }
            guard try Hashes.sha256Hex(ofFileAt: entry.destination) == entry.sha256 else {
                throw FrameworkModProjectionError.destinationHashMismatch(entry.destination)
            }
        }

        var removed: [URL] = []
        for entry in entries.sorted(by: { utf8Precedes($0.destination.path, $1.destination.path) })
            where FileManager.default.fileExists(atPath: entry.destination.path) {
            try removeItem(entry.destination)
            removed.append(entry.destination.standardizedFileURL)
        }
        return removed
    }

    private static let defaultRemoveItem: @Sendable (URL) throws -> Void = { url in
        try FileManager.default.removeItem(at: url)
    }

    private static func makeEntry(
        _ source: URL,
        destinationRoot: URL,
        kind: FrameworkProjectionKind,
        sourceRoot: URL,
        sourceRole: ModFrameworkSourceRole,
        relativeSourcePath: String,
        destinationName: String,
        gameRoot: URL,
        manager: FileManager
    ) throws -> FrameworkModProjectionEntry {
        let values = try source.resourceValues(
            forKeys: [.isSymbolicLinkKey, .isRegularFileKey]
        )
        if isSymbolicLink(source) || values.isSymbolicLink == true {
            throw FrameworkModProjectionError.sourceIsSymlink(source)
        }
        guard values.isRegularFile == true else {
            throw FrameworkModProjectionError.sourceIsNotRegular(source)
        }
        let destination = destinationRoot.appending(path: destinationName).standardizedFileURL
        guard isDescendant(destinationRoot.standardizedFileURL, of: gameRoot),
              isDescendant(destination, of: destinationRoot.standardizedFileURL)
        else {
            throw FrameworkModProjectionError.destinationIsUnsafe(destination)
        }
        guard !manager.fileExists(atPath: destination.path) else {
            throw FrameworkModProjectionError.destinationExists(destination)
        }
        let sha256 = try Hashes.sha256Hex(ofFileAt: source)
        return FrameworkModProjectionEntry(
            source: source.standardizedFileURL,
            destination: destination,
            kind: kind,
            sha256: sha256,
            sourceRoot: sourceRoot,
            sourceRole: sourceRole,
            relativeSourcePath: relativeSourcePath
        )
    }

    private static func copy(
        _ entry: FrameworkModProjectionEntry,
        manager: FileManager,
        created: inout [URL]
    ) throws {
        try manager.copyItem(at: entry.source, to: entry.destination)
        created.append(entry.destination)
        guard try Hashes.sha256Hex(ofFileAt: entry.destination) == entry.sha256 else {
            throw FrameworkModProjectionError.destinationHashMismatch(entry.destination)
        }
    }

    private static func projectionStem(
        sourceRoot: URL,
        relativePath: String,
        fileName: String
    ) -> String {
        let pathHash = Hashes.sha256Hex(of: Data(relativePath.utf8))
        return destinationPrefix + String(pathHash.prefix(16)) + "-" + fileName
    }

    private static let durableSchema = "archive-loader-framework-projection/v1"

    private static func writeRecord(
        _ entries: [FrameworkModProjectionEntry],
        game: GameInstall
    ) throws {
        let root = game.root.standardizedFileURL
        let durableEntries = try entries.map { entry in
            DurableProjectionEntry(
                sourcePath: try relativePath(of: entry.source, from: root),
                destinationPath: try relativePath(of: entry.destination, from: root),
                kind: entry.kind.rawValue,
                sha256: entry.sha256,
                sourceRootPath: try relativePath(of: entry.sourceRoot, from: root),
                sourceRole: entry.sourceRole.rawValue,
                relativeSourcePath: entry.relativeSourcePath,
                ownershipToken: entry.ownershipToken
            )
        }
        let record = DurableProjectionRecord(
            schema: durableSchema,
            sessionID: UUID().uuidString.lowercased(),
            entries: durableEntries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: game.stateDirectory,
            withIntermediateDirectories: true
        )
        try durableWrite(
            encoder.encode(record),
            to: recordURL(game: game)
        )
    }

    private static func readRecord(game: GameInstall) throws -> DurableProjectionRecord? {
        let url = recordURL(game: game)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard !isSymbolicLink(url) else {
            throw FrameworkModProjectionError.durableRecordMalformed(
                url,
                "record is a symbolic link"
            )
        }
        let record: DurableProjectionRecord
        do {
            record = try JSONDecoder().decode(
                DurableProjectionRecord.self,
                from: Data(contentsOf: url)
            )
        } catch {
            throw FrameworkModProjectionError.durableRecordMalformed(url, String(describing: error))
        }
        guard record.schema == durableSchema, !record.sessionID.isEmpty else {
            throw FrameworkModProjectionError.durableRecordMalformed(
                url,
                "unsupported schema or missing session id"
            )
        }
        return record
    }

    private static func entries(
        from record: DurableProjectionRecord,
        game: GameInstall
    ) throws -> [FrameworkModProjectionEntry] {
        let root = game.root.standardizedFileURL
        return try record.entries.map { durable in
            let source = try recordedURL(durable.sourcePath, root: root, record: recordURL(game: game))
            let destination = try recordedURL(
                durable.destinationPath,
                root: root,
                record: recordURL(game: game)
            )
            let sourceRoot = try recordedURL(
                durable.sourceRootPath,
                root: root,
                record: recordURL(game: game)
            )
            guard let kind = FrameworkProjectionKind(rawValue: durable.kind),
                  let role = ModFrameworkSourceRole(rawValue: durable.sourceRole),
                  durable.sha256.count == 64,
                  durable.sha256.unicodeScalars.allSatisfy({ scalar in
                      (scalar.value >= 48 && scalar.value <= 57)
                          || (scalar.value >= 97 && scalar.value <= 102)
                  }),
                  !durable.ownershipToken.isEmpty,
                  destination.lastPathComponent == durable.ownershipToken
            else {
                throw FrameworkModProjectionError.durableRecordMalformed(
                    recordURL(game: game),
                    "invalid projection entry"
                )
            }
            return FrameworkModProjectionEntry(
                source: source,
                destination: destination,
                kind: kind,
                sha256: durable.sha256,
                sourceRoot: sourceRoot,
                sourceRole: role,
                relativeSourcePath: durable.relativeSourcePath,
                ownershipToken: durable.ownershipToken
            )
        }
    }

    private static func durableRecordEntries(game: GameInstall) throws -> [FrameworkModProjectionEntry]? {
        guard let record = try readRecord(game: game) else { return nil }
        return try entries(from: record, game: game)
    }

    private static func acquireRecoveryLock(game: GameInstall) throws -> InstallationLock? {
        guard !InstallationLock.isHeldByCurrentProcess(game: game) else { return nil }
        return try InstallationLock.acquire(game: game)
    }

    private static func reconcileDurableProjection(game: GameInstall) throws {
        guard let entries = try durableRecordEntries(game: game) else { return }
        guard !entries.isEmpty else {
            try clearRecord(game: game)
            return
        }
        _ = try remove(entries: entries, game: game)
        try clearRecord(game: game)
        SessionProjectionRegistry.shared.clear(entries, for: game.root.standardizedFileURL)
    }

    private static func clearRecord(game: GameInstall) throws {
        let url = recordURL(game: game)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard !isSymbolicLink(url) else {
            throw FrameworkModProjectionError.durableRecordMalformed(
                url,
                "record is a symbolic link"
            )
        }
        try FileManager.default.removeItem(at: url)
        try syncDirectory(game.stateDirectory)
    }

    private static func relativePath(of url: URL, from root: URL) throws -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else {
            throw FrameworkModProjectionError.durableRecordMalformed(
                recordURL(game: GameInstall(root: root)),
                "path is outside the game root"
            )
        }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func recordedURL(
        _ path: String,
        root: URL,
        record: URL
    ) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/") else {
            throw FrameworkModProjectionError.durableRecordMalformed(record, "absolute path")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains("."), !components.contains(".."),
              !components.contains(where: { $0.isEmpty })
        else {
            throw FrameworkModProjectionError.durableRecordMalformed(record, "unsafe relative path")
        }
        return root.appending(path: path).standardizedFileURL
    }

    private static func durableWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        do {
            let handle = try FileHandle(forWritingTo: url)
            try handle.synchronize()
            try handle.close()
        } catch {
            throw FrameworkModProjectionError.durabilityFailure(url)
        }
        try syncDirectory(url.deletingLastPathComponent())
    }

    private static func syncDirectory(_ url: URL) throws {
        #if canImport(Darwin)
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY)
        }
        guard descriptor >= 0 else {
            throw FrameworkModProjectionError.durabilityFailure(url)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw FrameworkModProjectionError.durabilityFailure(url)
        }
        #else
        _ = url
        #endif
    }

    private static func validateSource(
        _ source: URL,
        role: ModFrameworkSourceRole,
        game: GameInstall,
        sourceRoot: URL
    ) throws {
        let expectedRoot: URL
        switch role {
        case .tweakDocument:
            expectedRoot = game.tweakModsDirectory.standardizedFileURL
        case .archivePayload:
            expectedRoot = game.modsEnabledDirectory.standardizedFileURL
        }
        let normalized = source.standardizedFileURL
        guard isDescendant(normalized, of: expectedRoot) else {
            throw FrameworkModProjectionError.sourceOutsideExpectedRoot(source, expectedRoot)
        }
        guard isDescendant(expectedRoot, of: game.root.standardizedFileURL),
              isDescendant(sourceRoot.standardizedFileURL, of: expectedRoot)
        else {
            throw FrameworkModProjectionError.sourceOutsideExpectedRoot(source, expectedRoot)
        }
        try rejectSymlinkedAncestors(from: game.root.standardizedFileURL, to: normalized)
        let canonicalRoot = expectedRoot.resolvingSymlinksInPath().standardizedFileURL
        let canonicalSource = normalized.resolvingSymlinksInPath().standardizedFileURL
        guard isDescendant(canonicalSource, of: canonicalRoot) else {
            throw FrameworkModProjectionError.sourceOutsideExpectedRoot(source, expectedRoot)
        }
    }

    private static func validateDestination(
        _ destination: URL,
        kind: FrameworkProjectionKind,
        gameRoot: URL
    ) throws {
        let root = kind == .tweak
            ? gameRoot.appending(path: "r6/tweaks")
            : gameRoot.appending(path: "archive/Mac/mod")
        guard isDescendant(destination.standardizedFileURL, of: root.standardizedFileURL) else {
            throw FrameworkModProjectionError.destinationIsUnsafe(destination)
        }
        try rejectSymlinkedAncestors(from: gameRoot, to: destination.standardizedFileURL)
    }

    private static func prepareDirectory(_ directory: URL, gameRoot: URL) throws {
        guard isDescendant(directory.standardizedFileURL, of: gameRoot) else {
            throw FrameworkModProjectionError.destinationIsUnsafe(directory)
        }
        let manager = FileManager.default
        var cursor = gameRoot
        let components = directory.pathComponents.dropFirst(gameRoot.pathComponents.count)
        for component in components {
            cursor.append(path: component)
            guard !manager.fileExists(atPath: cursor.path) else {
                let values = try cursor.resourceValues(
                    forKeys: [.isSymbolicLinkKey, .isDirectoryKey]
                )
                if isSymbolicLink(cursor) || values.isSymbolicLink == true {
                    throw FrameworkModProjectionError.projectionRootIsSymlink(cursor)
                }
                guard values.isDirectory == true else {
                    throw FrameworkModProjectionError.destinationIsUnsafe(cursor)
                }
                continue
            }
            try manager.createDirectory(at: cursor, withIntermediateDirectories: false)
        }
    }

    private static func validateGameRoot(_ root: URL, manager: FileManager) throws {
        if manager.fileExists(atPath: root.path) {
            let values = try root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if isSymbolicLink(root) || values.isSymbolicLink == true {
                throw FrameworkModProjectionError.projectionRootIsSymlink(root)
            }
            guard values.isDirectory == true else {
                throw FrameworkModProjectionError.destinationIsUnsafe(root)
            }
        } else {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
        }
    }

    private static func rejectSymlinkedAncestors(from base: URL, to url: URL) throws {
        let normalizedBase = base.standardizedFileURL
        let normalizedURL = url.standardizedFileURL
        guard isDescendant(normalizedURL, of: normalizedBase) else {
            throw FrameworkModProjectionError.destinationIsUnsafe(url)
        }
        var cursor = normalizedBase
        let components = normalizedURL.pathComponents.dropFirst(
            normalizedBase.pathComponents.count
        )
        for component in components {
            cursor.append(path: component)
            if isSymbolicLink(cursor) {
                throw FrameworkModProjectionError.sourceAncestorIsSymlink(cursor)
            }
        }
    }

    private static func isDescendant(_ url: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/")
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    private static func relativePath(_ url: URL, from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }
}

private final class SessionProjectionRegistry: @unchecked Sendable {
    static let shared = SessionProjectionRegistry()

    private let lock = NSLock()
    private var sessions: [String: [FrameworkModProjectionEntry]] = [:]

    func record(_ entries: [FrameworkModProjectionEntry], for root: URL) {
        lock.lock()
        defer { lock.unlock() }
        sessions[root.standardizedFileURL.path] = entries
    }

    func entries(for root: URL) -> [FrameworkModProjectionEntry] {
        lock.lock()
        defer { lock.unlock() }
        return sessions[root.standardizedFileURL.path] ?? []
    }

    func clear(_ entries: [FrameworkModProjectionEntry], for root: URL) {
        lock.lock()
        defer { lock.unlock() }
        let key = root.standardizedFileURL.path
        guard let current = sessions[key],
              Set(current.map(\.destination)) == Set(entries.map(\.destination))
        else { return }
        sessions.removeValue(forKey: key)
    }
}

private func utf8Precedes(_ left: String, _ right: String) -> Bool {
    Array(left.utf8).lexicographicallyPrecedes(Array(right.utf8))
}
