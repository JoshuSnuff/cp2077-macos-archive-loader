import Foundation
import Yams

public enum ModFramework: String, CaseIterable, Hashable, Sendable, Equatable {
    case archiveXL = "ArchiveXL"
    case tweakXL = "TweakXL"
}

public typealias ModFrameworkRequirement = ModFramework

public enum ModFrameworkSourceRole: String, Sendable, Equatable {
    case tweakDocument = "tweak-document"
    case archivePayload = "archive-payload"
}

public struct ModFrameworkSource: Sendable, Equatable {
    public let url: URL
    public let root: URL
    public let role: ModFrameworkSourceRole

    public init(url: URL, root: URL, role: ModFrameworkSourceRole) {
        self.url = url
        self.root = root
        self.role = role
    }
}

public enum ModFrameworkClassificationError: Error, CustomStringConvertible, Equatable {
    case unreadable(URL, String)
    case malformed(URL, String)

    public var description: String {
        switch self {
        case let .unreadable(url, detail):
            return "\(url.lastPathComponent): could not read framework metadata (\(detail))"
        case let .malformed(url, detail):
            return "\(url.lastPathComponent): malformed framework metadata (\(detail))"
        }
    }
}

public struct ModFrameworkClassification: Sendable, Equatable {
    public let mod: URL
    public let metadata: URL?
    public let associatedFiles: [URL]
    public let requirements: [ModFramework]
    public let isOpaque: Bool
    public let sourceRoot: URL
    public let sourceRole: ModFrameworkSourceRole

    public init(
        mod: URL,
        metadata: URL? = nil,
        associatedFiles: [URL] = [],
        requirements: [ModFramework] = [],
        isOpaque: Bool = false,
        sourceRoot: URL? = nil,
        sourceRole: ModFrameworkSourceRole? = nil
    ) {
        self.mod = mod
        self.metadata = metadata
        self.associatedFiles = associatedFiles.sorted(by: pathOrder)
        self.requirements = requirements
        self.isOpaque = isOpaque
        self.sourceRoot = (sourceRoot ?? mod.deletingLastPathComponent()).standardizedFileURL
        self.sourceRole = sourceRole ?? Self.inferredRole(for: mod)
    }

    public var isRuntimeOwned: Bool { !requirements.isEmpty }

    private static func inferredRole(for url: URL) -> ModFrameworkSourceRole {
        switch url.pathExtension.lowercased() {
        case "archive", "xl":
            return .archivePayload
        default:
            return .tweakDocument
        }
    }
}

/// Exact framework metadata classification shared by the offline planner and
/// native runtime projection. Installed plugin filenames are deliberately not
/// inputs to this value.
public struct ModFrameworkRequirements: Sendable, Equatable {
    public let classifications: [ModFrameworkClassification]

    public init(classifications: [ModFrameworkClassification]) {
        self.classifications = classifications.sorted {
            utf8Precedes($0.mod.path, $1.mod.path)
        }
    }

    public static func classify(mods: [URL]) throws -> ModFrameworkRequirements {
        try classify(sources: looseSources(mods))
    }

    public static func classify(game: GameInstall) throws -> ModFrameworkRequirements {
        try classify(sources: TweakModCollection.frameworkSources(game: game))
    }

    public static func classify(in directory: URL) throws -> ModFrameworkRequirements {
        try classify(mods: [directory])
    }

    public static func classify(sources: [ModFrameworkSource]) throws -> ModFrameworkRequirements {
        let discovered = try discover(sources: sources)
        let opaque = discovered.filter { isOpaque($0.url) }
        let sidecars = Set(opaque.flatMap { sidecarURLs(for: $0.url) }.map(\.standardizedFileURL))
        let sourceEntries = discovered.filter { !sidecars.contains($0.url.standardizedFileURL) }

        var classifications: [ModFrameworkClassification] = []
        for source in sourceEntries {
            let normalized = source.url.standardizedFileURL
            let opaqueMod = isOpaque(normalized)
            let metadataURLs = opaqueMod
                ? sidecarURLs(for: normalized).filter {
                    FileManager.default.fileExists(atPath: $0.path)
                }
                : [normalized]
            var requirements = Set<ModFramework>()
            var parsedMetadata: [(url: URL, requirements: Set<ModFramework>)] = []
            for metadataURL in metadataURLs {
                let found = try parseMetadata(at: metadataURL, reportedFor: normalized)
                parsedMetadata.append((metadataURL, found))
                requirements.formUnion(found)
            }

            let metadata = parsedMetadata.first { !$0.requirements.isEmpty }?.url
            classifications.append(ModFrameworkClassification(
                mod: normalized,
                metadata: metadata?.standardizedFileURL,
                associatedFiles: opaqueMod ? metadataURLs : [],
                requirements: ModFramework.allCases.filter { requirements.contains($0) },
                isOpaque: opaqueMod,
                sourceRoot: source.root,
                sourceRole: source.role
            ))
        }
        return ModFrameworkRequirements(classifications: classifications)
    }

    public var archiveXLMods: [URL] {
        mods(requiring: .archiveXL)
    }

    public var archiveXL: [URL] { archiveXLMods }

    public var tweakXLMods: [URL] {
        mods(requiring: .tweakXL)
    }

    public var tweakXL: [URL] { tweakXLMods }

    public var runtimeOwnedMods: [URL] {
        classifications.filter(\.isRuntimeOwned).map(\.mod).sorted(by: pathOrder)
    }

    public var runtimeMods: [URL] { runtimeOwnedMods }

    public var requiresArchiveXL: Bool { !archiveXLMods.isEmpty }
    public var requiresTweakXL: Bool { !tweakXLMods.isEmpty }

    /// Text documents with no exact framework requirement retain the legacy
    /// offline planner path. Opaque payloads are never sent to that parser.
    public var offlineMods: [URL] {
        classifications
            .filter { !$0.isOpaque && !$0.isRuntimeOwned }
            .map(\.mod)
            .sorted(by: pathOrder)
    }

    public var unknownMods: [URL] {
        classifications
            .filter { $0.isOpaque && !$0.isRuntimeOwned }
            .map(\.mod)
            .sorted(by: pathOrder)
    }

    public func classification(for mod: URL) -> ModFrameworkClassification? {
        let normalized = mod.standardizedFileURL
        return classifications.first { $0.mod.standardizedFileURL == normalized }
    }

    private func mods(requiring framework: ModFramework) -> [URL] {
        classifications
            .filter { $0.requirements.contains(framework) }
            .map(\.mod)
            .sorted(by: pathOrder)
    }

    private static func looseSources(_ mods: [URL]) throws -> [ModFrameworkSource] {
        var result: [ModFrameworkSource] = []
        for input in mods {
            let url = input.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw ModFrameworkClassificationError.unreadable(url, "path does not exist")
            }
            if isDirectory.boolValue {
                for file in try files(in: url) {
                    result.append(ModFrameworkSource(
                        url: file,
                        root: url,
                        role: inferredRole(for: file)
                    ))
                }
            } else {
                result.append(ModFrameworkSource(
                    url: url,
                    root: url.deletingLastPathComponent(),
                    role: inferredRole(for: url)
                ))
            }
        }
        return result
    }

    private static func discover(sources: [ModFrameworkSource]) throws -> [ModFrameworkSource] {
        var result: [ModFrameworkSource] = []
        for source in sources {
            let url = source.url.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw ModFrameworkClassificationError.unreadable(url, "path does not exist")
            }
            if isDirectory.boolValue {
                for file in try files(in: url) {
                    result.append(ModFrameworkSource(url: file, root: source.root, role: source.role))
                }
            } else {
                result.append(ModFrameworkSource(
                    url: url,
                    root: source.root,
                    role: source.role
                ))
            }
        }
        var unique = Set<URL>()
        return result.filter { unique.insert($0.url.standardizedFileURL).inserted }
            .sorted { utf8Precedes($0.url.path, $1.url.path) }
    }

    private static func files(in directory: URL) throws -> [URL] {
        let supported = Set(["yaml", "yml", "tweak", "xl", "archive"])
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [URL] = []
        for case let item as URL in enumerator {
            guard supported.contains(item.pathExtension.lowercased()) else { continue }
            let values = try? item.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values?.isRegularFile == true || values?.isSymbolicLink == true else {
                continue
            }
            found.append(item.standardizedFileURL)
        }
        return found.sorted { utf8Precedes($0.path, $1.path) }
    }

    private static func inferredRole(for url: URL) -> ModFrameworkSourceRole {
        switch url.pathExtension.lowercased() {
        case "archive", "xl":
            return .archivePayload
        default:
            return .tweakDocument
        }
    }

    private static func isOpaque(_ url: URL) -> Bool {
        ["xl", "archive"].contains(url.pathExtension.lowercased())
    }

    private static func sidecarURLs(for url: URL) -> [URL] {
        var candidates: [URL] = []
        if url.pathExtension.lowercased() == "archive" {
            candidates.append(URL(fileURLWithPath: url.path + ".xl"))
        }
        candidates.append(contentsOf: ["yaml", "yml", "tweak"].map {
            URL(fileURLWithPath: url.path + "." + $0)
        })
        candidates.append(contentsOf: ["yaml", "yml", "tweak"].map {
            url.deletingPathExtension().appendingPathExtension($0)
        })
        var unique = Set<URL>()
        return candidates
            .map(\.standardizedFileURL)
            .filter { unique.insert($0).inserted }
            .sorted(by: pathOrder)
    }

    private static func parseMetadata(at url: URL, reportedFor source: URL) throws -> Set<ModFramework> {
        let contents: String
        do {
            contents = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ModFrameworkClassificationError.unreadable(
                source,
                "metadata \(url.lastPathComponent) is not valid UTF-8"
            )
        }

        do {
            guard let root = try Yams.compose(yaml: contents) else { return [] }
            return requirements(in: root)
        } catch {
            throw ModFrameworkClassificationError.malformed(source, String(describing: error))
        }
    }

    private static func requirements(in root: Yams.Node) -> Set<ModFramework> {
        guard case let .mapping(mapping) = root else { return [] }
        var result = Set<ModFramework>()
        for pair in mapping {
            guard let key = pair.key.string,
                  key == "requires" || key == "dependencies",
                  case let .sequence(values) = pair.value
            else { continue }
            for value in values {
                guard case let .scalar(scalar) = value else { continue }
                if let framework = ModFramework(rawValue: scalar.string) {
                    result.insert(framework)
                }
            }
        }
        return result
    }
}

private func pathOrder(_ left: URL, _ right: URL) -> Bool {
    utf8Precedes(left.path, right.path)
}

private func utf8Precedes(_ left: String, _ right: String) -> Bool {
    Array(left.utf8).lexicographicallyPrecedes(Array(right.utf8))
}
