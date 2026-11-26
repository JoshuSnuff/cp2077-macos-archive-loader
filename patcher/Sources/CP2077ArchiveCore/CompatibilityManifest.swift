import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum CompatibilityManifestError: Error, CustomStringConvertible {
    case invalidJSON
    case invalidSchema(String)
    case invalidPath(field: String, value: String)
    case duplicatePath(namespace: String, value: String)
    case invalidHash(field: String, value: String)
    case invalidUUID(String)
    case missingSelfEntry
    case duplicateSelfEntry
    case malformedSelfEntry
    case selfHashMismatch(expected: String, actual: String)
    case missingMetadata(String)
    case malformedMetadata(String)
    case commandFailed(String)
    case sourceMissing(String)
    case sourceHashMismatch(path: String, expected: String, actual: String)
    case unsafeSourcePath(String)
    case invalidRuntimeRole(String)
    case invalidRuntimeEnvironment(String)
    case sourceIsSymlink(String)
    case sourceNotRegularFile(String)
    case sourceNotExecutable(String)
    case invalidMachO(String)
    case codeSigningFailed(String)
    case quarantinedSource(String)
    case quarantineCheckFailed(String)

    public var description: String {
        switch self {
        case .invalidJSON:
            return "compatibility manifest is not valid JSON"
        case let .invalidSchema(message):
            return "invalid compatibility manifest schema: \(message)"
        case let .invalidPath(field, value):
            return "invalid \(field) path: \(value)"
        case let .duplicatePath(namespace, value):
            return "duplicate \(namespace) path: \(value)"
        case let .invalidHash(field, value):
            return "invalid \(field) SHA-256: \(value)"
        case let .invalidUUID(value):
            return "invalid executable LC_UUID: \(value)"
        case .missingSelfEntry:
            return "compatibility manifest is missing its managed self-entry"
        case .duplicateSelfEntry:
            return "compatibility manifest has duplicate managed self-entries"
        case .malformedSelfEntry:
            return "compatibility manifest self-entry has no 64-character hash token"
        case let .selfHashMismatch(expected, actual):
            return "compatibility manifest self-hash mismatch: expected \(expected), calculated \(actual)"
        case let .missingMetadata(path):
            return "required compatibility metadata is missing: \(path)"
        case let .malformedMetadata(path):
            return "required compatibility metadata is malformed: \(path)"
        case let .commandFailed(command):
            return "compatibility metadata command failed: \(command)"
        case let .sourceMissing(path):
            return "managed package source is missing: \(path)"
        case let .sourceHashMismatch(path, expected, actual):
            return "managed package source hash mismatch for \(path): expected \(expected), found \(actual)"
        case let .unsafeSourcePath(path):
            return "managed package source escapes its root: \(path)"
        case let .invalidRuntimeRole(role):
            return "invalid framework runtime role mapping: \(role)"
        case let .invalidRuntimeEnvironment(key):
            return "invalid framework runtime environment: \(key)"
        case let .sourceIsSymlink(path):
            return "managed package source must not be a symlink: \(path)"
        case let .sourceNotRegularFile(path):
            return "managed package source is not a regular file: \(path)"
        case let .sourceNotExecutable(path):
            return "framework runtime binary is not executable: \(path)"
        case let .invalidMachO(path):
            return "framework runtime binary is not a valid arm64 Mach-O: \(path)"
        case let .codeSigningFailed(path):
            return "code-signing verification failed: \(path)"
        case let .quarantinedSource(path):
            return "quarantined managed source is not allowed: \(path)"
        case let .quarantineCheckFailed(path):
            return "could not inspect quarantine state: \(path)"
        }
    }
}

public struct CompatibilityMetadataSource: Codable, Equatable, Sendable {
    public var path: String
    public var key: String?
    public var command: String?
    public var loadCommand: String?

    public init(path: String, key: String? = nil, command: String? = nil, loadCommand: String? = nil) {
        self.path = path
        self.key = key
        self.command = command
        self.loadCommand = loadCommand
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case key
        case command
        case loadCommand
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try requireKnownKeys(container, expected: ["path", "key", "command", "loadCommand"])
        path = try container.decode(String.self, forKey: .path)
        key = try container.decodeIfPresent(String.self, forKey: .key)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        loadCommand = try container.decodeIfPresent(String.self, forKey: .loadCommand)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encodeIfPresent(key, forKey: .key)
        try container.encodeIfPresent(command, forKey: .command)
        try container.encodeIfPresent(loadCommand, forKey: .loadCommand)
    }
}

public struct CompatibilityMetadataSources: Codable, Equatable, Sendable {
    public var version: CompatibilityMetadataSource
    public var bundleVersion: CompatibilityMetadataSource
    public var gogBuildId: CompatibilityMetadataSource
    public var architecture: CompatibilityMetadataSource
    public var executableUuid: CompatibilityMetadataSource
    public var executableSha256: CompatibilityMetadataSource

    public init(
        version: CompatibilityMetadataSource,
        bundleVersion: CompatibilityMetadataSource,
        gogBuildId: CompatibilityMetadataSource,
        architecture: CompatibilityMetadataSource,
        executableUuid: CompatibilityMetadataSource,
        executableSha256: CompatibilityMetadataSource
    ) {
        self.version = version
        self.bundleVersion = bundleVersion
        self.gogBuildId = gogBuildId
        self.architecture = architecture
        self.executableUuid = executableUuid
        self.executableSha256 = executableSha256
    }

    public static let authoritative = CompatibilityMetadataSources(
        version: CompatibilityMetadataSource(
            path: "Cyberpunk2077.app/Contents/Info.plist",
            key: "CFBundleShortVersionString"
        ),
        bundleVersion: CompatibilityMetadataSource(
            path: "Cyberpunk2077.app/Contents/Info.plist",
            key: "CFBundleVersion"
        ),
        gogBuildId: CompatibilityMetadataSource(
            path: "Contents/Resources/goggame-1423049311.info",
            key: "buildId"
        ),
        architecture: CompatibilityMetadataSource(
            path: "Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077",
            command: "lipo -archs"
        ),
        executableUuid: CompatibilityMetadataSource(
            path: "Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077",
            command: "otool -arch arm64 -l",
            loadCommand: "LC_UUID"
        ),
        executableSha256: CompatibilityMetadataSource(
            path: "Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077",
            command: "shasum -a 256"
        )
    )

    private enum CodingKeys: String, CodingKey {
        case version
        case bundleVersion
        case gogBuildId
        case architecture
        case executableUuid
        case executableSha256
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try requireKnownKeys(container, expected: ["version", "bundleVersion", "gogBuildId", "architecture", "executableUuid", "executableSha256"])
        version = try container.decode(CompatibilityMetadataSource.self, forKey: .version)
        bundleVersion = try container.decode(CompatibilityMetadataSource.self, forKey: .bundleVersion)
        gogBuildId = try container.decode(CompatibilityMetadataSource.self, forKey: .gogBuildId)
        architecture = try container.decode(CompatibilityMetadataSource.self, forKey: .architecture)
        executableUuid = try container.decode(CompatibilityMetadataSource.self, forKey: .executableUuid)
        executableSha256 = try container.decode(CompatibilityMetadataSource.self, forKey: .executableSha256)
    }
}

public struct CompatibilityExecutable: Codable, Equatable, Sendable {
    public var path: String
    public var uuid: String
    public var sha256: String

    public init(path: String, uuid: String, sha256: String) {
        self.path = path
        self.uuid = uuid
        self.sha256 = sha256
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case uuid
        case sha256
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try requireKnownKeys(container, expected: ["path", "uuid", "sha256"])
        path = try container.decode(String.self, forKey: .path)
        uuid = try container.decode(String.self, forKey: .uuid)
        sha256 = try container.decode(String.self, forKey: .sha256)
    }
}

public struct CompatibilityTarget: Codable, Equatable, Sendable {
    public var game: String
    public var distribution: String
    public var platform: String
    public var architecture: String
    public var version: String
    public var bundleVersion: String
    public var gogBuildId: String
    public var executable: CompatibilityExecutable

    public init(
        game: String,
        distribution: String,
        platform: String,
        architecture: String,
        version: String,
        bundleVersion: String,
        gogBuildId: String,
        executable: CompatibilityExecutable
    ) {
        self.game = game
        self.distribution = distribution
        self.platform = platform
        self.architecture = architecture
        self.version = version
        self.bundleVersion = bundleVersion
        self.gogBuildId = gogBuildId
        self.executable = executable
    }

    private enum CodingKeys: String, CodingKey {
        case game
        case distribution
        case platform
        case architecture
        case version
        case bundleVersion
        case gogBuildId
        case executable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try requireKnownKeys(container, expected: ["game", "distribution", "platform", "architecture", "version", "bundleVersion", "gogBuildId", "executable"])
        game = try container.decode(String.self, forKey: .game)
        distribution = try container.decode(String.self, forKey: .distribution)
        platform = try container.decode(String.self, forKey: .platform)
        architecture = try container.decode(String.self, forKey: .architecture)
        version = try container.decode(String.self, forKey: .version)
        bundleVersion = try container.decode(String.self, forKey: .bundleVersion)
        gogBuildId = try container.decode(String.self, forKey: .gogBuildId)
        executable = try container.decode(CompatibilityExecutable.self, forKey: .executable)
    }
}

public struct CompatibilityManagedFile: Codable, Equatable, Sendable {
    public var packagePath: String
    public var gamePath: String
    public var sha256: String

    public init(packagePath: String, gamePath: String, sha256: String) {
        self.packagePath = packagePath
        self.gamePath = gamePath
        self.sha256 = sha256
    }

    private enum CodingKeys: String, CodingKey {
        case packagePath
        case gamePath
        case sha256
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try requireKnownKeys(container, expected: ["packagePath", "gamePath", "sha256"])
        packagePath = try container.decode(String.self, forKey: .packagePath)
        gamePath = try container.decode(String.self, forKey: .gamePath)
        sha256 = try container.decode(String.self, forKey: .sha256)
    }
}

public enum FrameworkRuntimeRole: String, Codable, CaseIterable, Equatable, Sendable {
    case red4extLoader = "red4ext-loader"
    case tweakXLPlugin = "tweakxl-plugin"
    case archiveXLPlugin = "archivexl-plugin"

    public static let required: [FrameworkRuntimeRole] = [
        .red4extLoader,
        .tweakXLPlugin,
        .archiveXLPlugin,
    ]

    public var nativeGamePath: String {
        switch self {
        case .red4extLoader:
            return "red4ext/RED4ext.dylib"
        case .tweakXLPlugin:
            return "red4ext/plugins/TweakXL.dylib"
        case .archiveXLPlugin:
            return "red4ext/plugins/ArchiveXL.dylib"
        }
    }
}

public struct FrameworkRuntimeEnvironment: Codable, Equatable, Sendable {
    public var mode: String
    public var paths: [String]?
    public var value: String?

    public init(mode: String, paths: [String]? = nil, value: String? = nil) {
        self.mode = mode
        self.paths = paths
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CompatibilityAnyCodingKey.self)
        let expected = Set(["mode", "paths", "value"])
        let actual = Set(container.allKeys.map(\.stringValue))
        guard actual.isSubset(of: expected) else {
            throw CompatibilityManifestError.invalidSchema(
                "unknown field(s): \(actual.subtracting(expected).sorted().joined(separator: ", "))"
            )
        }
        mode = try container.decode(String.self, forKey: CompatibilityAnyCodingKey(stringValue: "mode"))
        paths = try container.decodeIfPresent(
            [String].self,
            forKey: CompatibilityAnyCodingKey(stringValue: "paths")
        )
        value = try container.decodeIfPresent(
            String.self,
            forKey: CompatibilityAnyCodingKey(stringValue: "value")
        )
    }
}

public struct FrameworkRuntimeManifest: Codable, Equatable, Sendable {
    public static let schema = "archive-loader-framework-runtime/v1"

    public var schema: String
    public var roles: [String]
    public var environment: [String: FrameworkRuntimeEnvironment]

    public init(
        schema: String,
        roles: [String],
        environment: [String: FrameworkRuntimeEnvironment]
    ) {
        self.schema = schema
        self.roles = roles
        self.environment = environment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CompatibilityAnyCodingKey.self)
        let expected = Set(["schema", "roles", "environment"])
        let actual = Set(container.allKeys.map(\.stringValue))
        guard actual.isSubset(of: expected) else {
            throw CompatibilityManifestError.invalidSchema(
                "unknown field(s): \(actual.subtracting(expected).sorted().joined(separator: ", "))"
            )
        }
        schema = try container.decode(String.self, forKey: CompatibilityAnyCodingKey(stringValue: "schema"))
        roles = try container.decode([String].self, forKey: CompatibilityAnyCodingKey(stringValue: "roles"))
        environment = try container.decode(
            [String: FrameworkRuntimeEnvironment].self,
            forKey: CompatibilityAnyCodingKey(stringValue: "environment")
        )
    }

    public func validate(managedFiles: [CompatibilityManagedFile]) throws {
        guard schema == Self.schema else {
            throw CompatibilityManifestError.invalidSchema("unsupported frameworkRuntime schema \(schema)")
        }

        let expectedRoles = Set(FrameworkRuntimeRole.required.map(\.rawValue))
        guard Set(roles) == expectedRoles, roles.count == expectedRoles.count else {
            throw CompatibilityManifestError.invalidRuntimeRole(roles.joined(separator: ", "))
        }

        let expectedEnvironment = Set(["DYLD_INSERT_LIBRARIES", "DYLD_FORCE_FLAT_NAMESPACE"])
        guard Set(environment.keys) == expectedEnvironment else {
            throw CompatibilityManifestError.invalidRuntimeEnvironment(
                environment.keys.sorted().joined(separator: ", ")
            )
        }

        guard let insert = environment["DYLD_INSERT_LIBRARIES"],
              insert.mode == "prepend",
              insert.paths == [FrameworkRuntimeRole.red4extLoader.nativeGamePath],
              insert.value == nil
        else {
            throw CompatibilityManifestError.invalidRuntimeEnvironment("DYLD_INSERT_LIBRARIES")
        }

        guard let flatNamespace = environment["DYLD_FORCE_FLAT_NAMESPACE"],
              flatNamespace.mode == "replace",
              flatNamespace.paths == nil,
              flatNamespace.value == "1"
        else {
            throw CompatibilityManifestError.invalidRuntimeEnvironment("DYLD_FORCE_FLAT_NAMESPACE")
        }

        for role in FrameworkRuntimeRole.required {
            let mappings = managedFiles.filter { $0.gamePath == role.nativeGamePath }
            guard mappings.count == 1 else {
                throw CompatibilityManifestError.invalidRuntimeRole(
                    "\(role.rawValue) requires exactly one \(role.nativeGamePath) mapping"
                )
            }
        }
    }
}

private struct CompatibilityAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

public enum CompatibilityPreflight {
    public typealias CommandRunner = (_ command: String, _ arguments: [String]) throws -> String
    public typealias QuarantineChecker = (_ url: URL) throws -> Bool

    public static func run(_ command: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            throw CompatibilityManifestError.commandFailed(command)
        }
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw CompatibilityManifestError.commandFailed(command)
        }
        return String(decoding: data, as: UTF8.self)
    }

    public static func hasQuarantine(_ url: URL) throws -> Bool {
        #if canImport(Darwin)
        let result = url.path.withCString { path in
            "com.apple.quarantine".withCString { name in
                Darwin.getxattr(path, name, nil, 0, 0, 0)
            }
        }
        guard result >= 0 else {
            let errorNumber = errno
            guard errorNumber == ENOATTR else {
                throw CompatibilityManifestError.quarantineCheckFailed(url.path)
            }
            return false
        }
        return true
        #else
        return false
        #endif
    }
}

public struct CompatibilityManifest: Codable, Equatable, Sendable {
    public static let schema = "cp2077-compatibility/v1"
    public static let executablePath = "Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"

    public var schema: String
    public var loaderVersion: String
    public var target: CompatibilityTarget
    public var metadataSources: CompatibilityMetadataSources
    public var managedFiles: [CompatibilityManagedFile]
    public var frameworkRuntime: FrameworkRuntimeManifest?

    public init(
        schema: String,
        loaderVersion: String,
        target: CompatibilityTarget,
        metadataSources: CompatibilityMetadataSources,
        managedFiles: [CompatibilityManagedFile],
        frameworkRuntime: FrameworkRuntimeManifest? = nil
    ) {
        self.schema = schema
        self.loaderVersion = loaderVersion
        self.target = target
        self.metadataSources = metadataSources
        self.managedFiles = managedFiles
        self.frameworkRuntime = frameworkRuntime
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case loaderVersion
        case target
        case metadataSources
        case managedFiles
        case frameworkRuntime
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try requireKnownKeys(container, expected: ["schema", "loaderVersion", "target", "metadataSources", "managedFiles", "frameworkRuntime"])
        schema = try container.decode(String.self, forKey: .schema)
        loaderVersion = try container.decode(String.self, forKey: .loaderVersion)
        target = try container.decode(CompatibilityTarget.self, forKey: .target)
        metadataSources = try container.decode(CompatibilityMetadataSources.self, forKey: .metadataSources)
        managedFiles = try container.decode([CompatibilityManagedFile].self, forKey: .managedFiles)
        frameworkRuntime = try container.decodeIfPresent(FrameworkRuntimeManifest.self, forKey: .frameworkRuntime)
        try validate(allowMaskedSelfHash: true)
    }

    public func validate() throws {
        try validate(allowMaskedSelfHash: false)
    }

    func validate(allowMaskedSelfHash: Bool) throws {
        guard schema == Self.schema else {
            throw CompatibilityManifestError.invalidSchema("unsupported schema \(schema)")
        }
        guard LoaderVersion.parse(loaderVersion) != nil else {
            throw CompatibilityManifestError.invalidSchema("loaderVersion must be MAJOR.MINOR.PATCH")
        }
        guard target.game == "Cyberpunk 2077",
              target.distribution == "gog",
              target.platform == "macos",
              target.architecture == "arm64",
              target.version == "2.5.0",
              target.bundleVersion == "5814786",
              target.gogBuildId == "60152051833789151"
        else {
            throw CompatibilityManifestError.invalidSchema("target does not describe the supported Cyberpunk 2077 2.5.0 GOG build")
        }
        guard target.executable.path == Self.executablePath else {
            throw CompatibilityManifestError.invalidPath(field: "target.executable", value: target.executable.path)
        }
        guard isCanonicalUUID(target.executable.uuid), target.executable.uuid == target.executable.uuid.lowercased() else {
            throw CompatibilityManifestError.invalidUUID(target.executable.uuid)
        }
        try validateHash(target.executable.sha256, field: "target.executable.sha256")
        guard metadataSources == .authoritative else {
            throw CompatibilityManifestError.invalidSchema("metadataSources must use the authoritative production paths and commands")
        }
        guard !managedFiles.isEmpty else {
            throw CompatibilityManifestError.invalidSchema("managedFiles must not be empty")
        }

        var packagePaths = Set<String>()
        var gamePaths = Set<String>()
        var selfEntries = 0
        for (index, entry) in managedFiles.enumerated() {
            try validateRelativePath(entry.packagePath, field: "managedFiles[\(index)].packagePath")
            try validateRelativePath(entry.gamePath, field: "managedFiles[\(index)].gamePath")
            guard entry.packagePath.hasPrefix("archive-loader/") else {
                throw CompatibilityManifestError.invalidPath(
                    field: "managedFiles[\(index)].packagePath",
                    value: entry.packagePath
                )
            }
            guard packagePaths.insert(entry.packagePath).inserted else {
                throw CompatibilityManifestError.duplicatePath(namespace: "packagePath", value: entry.packagePath)
            }
            guard gamePaths.insert(entry.gamePath).inserted else {
                throw CompatibilityManifestError.duplicatePath(namespace: "gamePath", value: entry.gamePath)
            }

            let isSelfEntry = entry.packagePath == "archive-loader/compatibility/manifest.json"
                && entry.gamePath == "archive-loader/compatibility/manifest.json"
            if isSelfEntry { selfEntries += 1 }
            if allowMaskedSelfHash && isSelfEntry && entry.sha256 == String(repeating: "0", count: 64) {
                continue
            }
            try validateHash(entry.sha256, field: "managedFiles[\(index)].sha256")
        }
        guard selfEntries > 0 else { throw CompatibilityManifestError.missingSelfEntry }
        guard selfEntries == 1 else { throw CompatibilityManifestError.duplicateSelfEntry }
        try frameworkRuntime?.validate(managedFiles: managedFiles)
    }

    public static func load(from url: URL) throws -> CompatibilityManifest {
        try CompatibilityManifestDocument(bytes: Data(contentsOf: url)).manifest
    }
}

public struct CompatibilityManifestDocument: Sendable {
    public let bytes: Data
    public let manifest: CompatibilityManifest
    public let selfHashRange: Range<Data.Index>
    public let maskedBytes: Data
    public let maskedSelfHash: String

    public init(bytes: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: bytes),
              JSONSerialization.isValidJSONObject(object)
        else {
            throw CompatibilityManifestError.invalidJSON
        }
        let decoded: CompatibilityManifest
        do {
            decoded = try JSONDecoder().decode(CompatibilityManifest.self, from: bytes)
        } catch let error as CompatibilityManifestError {
            throw error
        } catch {
            throw CompatibilityManifestError.invalidSchema(error.localizedDescription)
        }
        try decoded.validate()
        let range = try JSONSelfHashLocator.locate(in: bytes)
        let declared = String(decoding: bytes[range], as: UTF8.self)
        guard isLowercaseSHA256(declared, allowZero: false) else {
            throw CompatibilityManifestError.malformedSelfEntry
        }
        var masked = bytes
        masked.replaceSubrange(range, with: Data(repeating: 0x30, count: range.count))
        let calculated = Hashes.sha256Hex(of: masked)
        guard calculated == declared else {
            throw CompatibilityManifestError.selfHashMismatch(expected: declared, actual: calculated)
        }
        self.bytes = bytes
        self.manifest = decoded
        self.selfHashRange = range
        self.maskedBytes = masked
        self.maskedSelfHash = calculated
    }
}

public enum CompatibilityManifestCodec {
    public static func encode(_ manifest: CompatibilityManifest) throws -> Data {
        try manifest.validate(allowMaskedSelfHash: true)
        var maskedManifest = manifest
        guard let index = maskedManifest.managedFiles.firstIndex(where: {
            $0.packagePath == "archive-loader/compatibility/manifest.json"
                && $0.gamePath == "archive-loader/compatibility/manifest.json"
        }) else {
            throw CompatibilityManifestError.missingSelfEntry
        }
        maskedManifest.managedFiles[index].sha256 = String(repeating: "0", count: 64)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var bytes = try encoder.encode(maskedManifest)
        bytes.append(0x0a)

        let range = try JSONSelfHashLocator.locate(in: bytes)
        var masked = bytes
        masked.replaceSubrange(range, with: Data(repeating: 0x30, count: range.count))
        let digest = Hashes.sha256Hex(of: masked)
        bytes.replaceSubrange(range, with: Data(digest.utf8))
        _ = try CompatibilityManifestDocument(bytes: bytes)
        return bytes
    }
}

private func requireKnownKeys<K: CodingKey>(
    _ container: KeyedDecodingContainer<K>,
    expected: Set<String>
) throws {
    // The decoder's CodingKeys already rejects unknown keys by omission only
    // when this explicit check is present. This keeps malformed release JSON
    // from silently acquiring a second interpretation in a later consumer.
    let known = Set(container.allKeys.map(\.stringValue))
    guard known.isSubset(of: expected) else {
        throw CompatibilityManifestError.invalidSchema("unknown field(s): \(known.subtracting(expected).sorted().joined(separator: ", "))")
    }
}

private func validateRelativePath(_ value: String, field: String) throws {
    guard !value.isEmpty,
          !value.hasPrefix("/"),
          !value.hasSuffix("/"),
          !value.hasPrefix("./"),
          !value.contains("\\"),
          !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
        throw CompatibilityManifestError.invalidPath(field: field, value: value)
    }
    let components = value.split(separator: "/", omittingEmptySubsequences: false)
    guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
          components.joined(separator: "/") == value
    else {
        throw CompatibilityManifestError.invalidPath(field: field, value: value)
    }
}

private func validateHash(_ value: String, field: String) throws {
    guard isLowercaseSHA256(value, allowZero: false) else {
        throw CompatibilityManifestError.invalidHash(field: field, value: value)
    }
}

private func isLowercaseSHA256(_ value: String, allowZero: Bool) -> Bool {
    guard value.utf8.count == 64,
          value.unicodeScalars.allSatisfy({ scalar in
              (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 97 && scalar.value <= 102)
          })
    else { return false }
    return allowZero || value != String(repeating: "0", count: 64)
}

private func isCanonicalUUID(_ value: String) -> Bool {
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.map(\.count) == [8, 4, 4, 4, 12] else { return false }
    return parts.joined().unicodeScalars.allSatisfy { scalar in
        (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 97 && scalar.value <= 102)
    }
}

private enum JSONSelfHashLocator {
    static func locate(in data: Data) throws -> Range<Data.Index> {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object)
        else {
            throw CompatibilityManifestError.invalidJSON
        }
        var parser = JSONByteParser(bytes: Array(data))
        let root = try parser.parse()
        guard let fields = root.objectFields,
              let managed = fields.first(where: { $0.key == "managedFiles" })?.value,
              let entries = managed.arrayElements
        else {
            throw CompatibilityManifestError.missingSelfEntry
        }

        var ranges: [Range<Int>] = []
        for entry in entries {
            guard let object = entry.objectFields else {
                throw CompatibilityManifestError.invalidSchema("managedFiles must contain objects")
            }
            let package = object.first(where: { $0.key == "packagePath" })?.value.stringValue
            let game = object.first(where: { $0.key == "gamePath" })?.value.stringValue
            guard package == "archive-loader/compatibility/manifest.json",
                  game == "archive-loader/compatibility/manifest.json"
            else { continue }
            guard let hash = object.first(where: { $0.key == "sha256" })?.value,
                  let range = hash.stringRange,
                  range.count == 64
            else { throw CompatibilityManifestError.malformedSelfEntry }
            ranges.append(range)
        }
        guard ranges.count > 0 else { throw CompatibilityManifestError.missingSelfEntry }
        guard ranges.count == 1 else { throw CompatibilityManifestError.duplicateSelfEntry }
        let range = ranges[0]
        guard data[range].allSatisfy({ byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }) else {
            throw CompatibilityManifestError.malformedSelfEntry
        }
        return range
    }
}

private struct JSONByteNode {
    var stringValue: String?
    var stringRange: Range<Int>?
    var objectFields: [(key: String, value: JSONByteNode)]?
    var arrayElements: [JSONByteNode]?
}

private struct JSONByteParser {
    let bytes: [UInt8]
    var index = 0

    mutating func parse() throws -> JSONByteNode {
        let value = try parseValue()
        skipWhitespace()
        guard index == bytes.count else { throw CompatibilityManifestError.invalidJSON }
        return value
    }

    mutating private func parseValue() throws -> JSONByteNode {
        skipWhitespace()
        guard index < bytes.count else { throw CompatibilityManifestError.invalidJSON }
        switch bytes[index] {
        case 0x7b: return try parseObject()
        case 0x5b: return try parseArray()
        case 0x22: return try parseString()
        default: return try parsePrimitive()
        }
    }

    mutating private func parseObject() throws -> JSONByteNode {
        index += 1
        var fields: [(key: String, value: JSONByteNode)] = []
        var keys = Set<String>()
        skipWhitespace()
        if consume(0x7d) { return JSONByteNode(stringValue: nil, stringRange: nil, objectFields: fields, arrayElements: nil) }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 0x22 else { throw CompatibilityManifestError.invalidJSON }
            let key = try parseString().stringValue ?? ""
            guard keys.insert(key).inserted else { throw CompatibilityManifestError.invalidJSON }
            skipWhitespace()
            guard consume(0x3a) else { throw CompatibilityManifestError.invalidJSON }
            let value = try parseValue()
            fields.append((key: key, value: value))
            skipWhitespace()
            if consume(0x7d) { break }
            guard consume(0x2c) else { throw CompatibilityManifestError.invalidJSON }
        }
        return JSONByteNode(stringValue: nil, stringRange: nil, objectFields: fields, arrayElements: nil)
    }

    mutating private func parseArray() throws -> JSONByteNode {
        index += 1
        var values: [JSONByteNode] = []
        skipWhitespace()
        if consume(0x5d) { return JSONByteNode(stringValue: nil, stringRange: nil, objectFields: nil, arrayElements: values) }
        while true {
            values.append(try parseValue())
            skipWhitespace()
            if consume(0x5d) { break }
            guard consume(0x2c) else { throw CompatibilityManifestError.invalidJSON }
        }
        return JSONByteNode(stringValue: nil, stringRange: nil, objectFields: nil, arrayElements: values)
    }

    mutating private func parseString() throws -> JSONByteNode {
        let start = index
        guard consume(0x22) else { throw CompatibilityManifestError.invalidJSON }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                index += 1
                let token = Data(bytes[start..<index])
                guard let value = try JSONSerialization.jsonObject(with: token, options: [.fragmentsAllowed]) as? String else {
                    throw CompatibilityManifestError.invalidJSON
                }
                return JSONByteNode(
                    stringValue: value,
                    stringRange: (start + 1)..<(index - 1),
                    objectFields: nil,
                    arrayElements: nil
                )
            }
            if byte == 0x5c {
                index += 2
            } else {
                index += 1
            }
        }
        throw CompatibilityManifestError.invalidJSON
    }

    mutating private func parsePrimitive() throws -> JSONByteNode {
        let start = index
        while index < bytes.count, ![0x20, 0x09, 0x0a, 0x0d, 0x2c, 0x5d, 0x7d].contains(bytes[index]) {
            index += 1
        }
        guard start < index else { throw CompatibilityManifestError.invalidJSON }
        let token = Data(bytes[start..<index])
        guard (try? JSONSerialization.jsonObject(with: token, options: [.fragmentsAllowed])) != nil else {
            throw CompatibilityManifestError.invalidJSON
        }
        return JSONByteNode(stringValue: nil, stringRange: nil, objectFields: nil, arrayElements: nil)
    }

    mutating private func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    mutating private func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0a, 0x0d].contains(bytes[index]) {
            index += 1
        }
    }
}
