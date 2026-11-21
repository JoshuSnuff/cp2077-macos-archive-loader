import Foundation

public struct CompatibilityIdentity: Equatable, Sendable {
    public let architecture: String
    public let version: String
    public let bundleVersion: String
    public let gogBuildId: String
    public let executableUUID: String
    public let executableSHA256: String

    public init(
        architecture: String,
        version: String,
        bundleVersion: String,
        gogBuildId: String,
        executableUUID: String,
        executableSHA256: String
    ) {
        self.architecture = architecture
        self.version = version
        self.bundleVersion = bundleVersion
        self.gogBuildId = gogBuildId
        self.executableUUID = executableUUID
        self.executableSHA256 = executableSHA256
    }
}

public enum CompatibilityIdentityReader {
    public typealias CommandRunner = (_ command: String, _ arguments: [String]) throws -> String

    public static func read(
        root: URL,
        manifest: CompatibilityManifest,
        commandRunner: CommandRunner? = nil
    ) throws -> CompatibilityIdentity {
        try manifest.validate(allowMaskedSelfHash: true)
        let sources = manifest.metadataSources
        let infoData = try readRequiredData(root: root, relativePath: sources.version.path)
        let info = try parsePlist(infoData, path: sources.version.path)
        let version = try requiredString(info, key: sources.version.key ?? "", path: sources.version.path)
        let bundleVersion = try requiredString(info, key: sources.bundleVersion.key ?? "", path: sources.bundleVersion.path)

        let gogData = try readRequiredData(root: root, relativePath: sources.gogBuildId.path)
        let gog = try parseJSONObject(gogData, path: sources.gogBuildId.path)
        let buildID = try requiredString(gog, key: sources.gogBuildId.key ?? "", path: sources.gogBuildId.path)

        let executableURL = root.appendingPathComponent(sources.architecture.path)
        guard FileManager.default.isReadableFile(atPath: executableURL.path) else {
            throw CompatibilityManifestError.missingMetadata(sources.architecture.path)
        }
        let run = commandRunner ?? defaultCommandRunner
        let architectureOutput = try run("lipo", ["-archs", executableURL.path])
        let architecture = architectureOutput.split { $0 == " " || $0 == "\n" || $0 == "\t" }
            .map(String.init)
        guard architecture.contains("arm64") else {
            throw CompatibilityManifestError.malformedMetadata("arm64 slice in \(sources.architecture.path)")
        }

        let uuidOutput = try run("otool", ["-arch", "arm64", "-l", executableURL.path])
        let uuid = try parseUUID(from: uuidOutput, path: sources.executableUuid.path)

        let digestOutput = try run("shasum", ["-a", "256", executableURL.path])
        let digest = try parseSHA256(from: digestOutput, path: sources.executableSha256.path)

        return CompatibilityIdentity(
            architecture: "arm64",
            version: version,
            bundleVersion: bundleVersion,
            gogBuildId: buildID,
            executableUUID: uuid,
            executableSHA256: digest
        )
    }

    private static func defaultCommandRunner(_ command: String, _ arguments: [String]) throws -> String {
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
}

public enum CompatibilityIdentityValidator {
    public static func mismatches(
        target: CompatibilityTarget,
        actual: CompatibilityIdentity
    ) -> [String] {
        var differences: [String] = []
        if actual.architecture != target.architecture { differences.append("architecture") }
        if actual.version != target.version { differences.append("version") }
        if actual.bundleVersion != target.bundleVersion { differences.append("bundleVersion") }
        if actual.gogBuildId != target.gogBuildId { differences.append("gogBuildId") }
        if actual.executableUUID != target.executable.uuid.lowercased() { differences.append("executable.uuid") }
        if actual.executableSHA256 != target.executable.sha256.lowercased() { differences.append("executable.sha256") }
        return differences
    }

    public static func requireMatch(
        target: CompatibilityTarget,
        actual: CompatibilityIdentity
    ) throws {
        let differences = mismatches(target: target, actual: actual)
        guard differences.isEmpty else {
            throw CompatibilityManifestError.invalidSchema(
                "target identity mismatch: \(differences.joined(separator: ", "))"
            )
        }
    }
}

private func readRequiredData(root: URL, relativePath: String) throws -> Data {
    let url = root.appendingPathComponent(relativePath)
    guard FileManager.default.isReadableFile(atPath: url.path) else {
        throw CompatibilityManifestError.missingMetadata(relativePath)
    }
    do {
        return try Data(contentsOf: url)
    } catch {
        throw CompatibilityManifestError.malformedMetadata(relativePath)
    }
}

private func parsePlist(_ data: Data, path: String) throws -> [String: Any] {
    do {
        guard let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw CompatibilityManifestError.malformedMetadata(path)
        }
        return value
    } catch let error as CompatibilityManifestError {
        throw error
    } catch {
        throw CompatibilityManifestError.malformedMetadata(path)
    }
}

private func parseJSONObject(_ data: Data, path: String) throws -> [String: Any] {
    do {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CompatibilityManifestError.malformedMetadata(path)
        }
        return value
    } catch let error as CompatibilityManifestError {
        throw error
    } catch {
        throw CompatibilityManifestError.malformedMetadata(path)
    }
}

private func requiredString(_ object: [String: Any], key: String, path: String) throws -> String {
    guard !key.isEmpty, let value = object[key] as? String, !value.isEmpty else {
        throw CompatibilityManifestError.malformedMetadata("\(path) missing \(key)")
    }
    return value
}

private func parseUUID(from output: String, path: String) throws -> String {
    for line in output.split(whereSeparator: \.isNewline) {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let uuidIndex = fields.firstIndex(where: { $0.lowercased() == "uuid" }),
              fields.count > uuidIndex + 1
        else { continue }
        let value = String(fields[uuidIndex + 1]).lowercased()
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.map(\.count) == [8, 4, 4, 4, 12],
              parts.joined().unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 97 && scalar.value <= 102)
              })
        else { throw CompatibilityManifestError.malformedMetadata(path) }
        return value
    }
    throw CompatibilityManifestError.malformedMetadata(path)
}

private func parseSHA256(from output: String, path: String) throws -> String {
    guard let token = output.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).first else {
        throw CompatibilityManifestError.malformedMetadata(path)
    }
    let value = String(token).lowercased()
    guard value.utf8.count == 64,
          value.unicodeScalars.allSatisfy({ scalar in
              (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 97 && scalar.value <= 102)
          })
    else { throw CompatibilityManifestError.malformedMetadata(path) }
    return value
}
