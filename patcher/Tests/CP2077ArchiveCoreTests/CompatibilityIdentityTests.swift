import CP2077ArchiveCore
import Foundation
import Testing

@Test func identityMismatchRejectsBuildAndUUIDChangesWithEqualMarketingVersion() {
    let target = targetIdentityTarget()
    let actual = CompatibilityIdentity(
        architecture: target.architecture,
        version: target.version,
        bundleVersion: "different-bundle",
        gogBuildId: "different-build",
        executableUUID: "fedcba98-7654-3210-fedc-ba9876543210",
        executableSHA256: String(repeating: "b", count: 64)
    )

    let mismatches = CompatibilityIdentityValidator.mismatches(target: target, actual: actual)
    #expect(mismatches.contains("bundleVersion"))
    #expect(mismatches.contains("gogBuildId"))
    #expect(mismatches.contains("executable.uuid"))
    #expect(!mismatches.contains("version"))
}

@Test func identityReaderRejectsCodeSigningFailureBeforeReturningIdentity() throws {
    let fixture = try IdentityFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    #expect(throws: CompatibilityManifestError.self) {
        try CompatibilityIdentityReader.read(
            root: fixture.root,
            manifest: fixture.manifest,
            commandRunner: { command, _ in
                if command == "codesign" { throw FixtureFailure.commandFailed }
                return fixture.output(for: command)
            },
            quarantineChecker: { _ in false }
        )
    }
}

@Test func identityReaderRejectsQuarantinedGameExecutable() throws {
    let fixture = try IdentityFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    #expect(throws: CompatibilityManifestError.self) {
        try CompatibilityIdentityReader.read(
            root: fixture.root,
            manifest: fixture.manifest,
            commandRunner: { command, _ in fixture.output(for: command) },
            quarantineChecker: { _ in true }
        )
    }
}

private enum FixtureFailure: Error {
    case commandFailed
}

private struct IdentityFixture {
    let root: URL
    let manifest: CompatibilityManifest

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "compatibility-identity-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: root.appending(path: "Cyberpunk2077.app/Contents/MacOS"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appending(path: "Contents/Resources"),
            withIntermediateDirectories: true
        )
        try Data("executable".utf8).write(
            to: root.appending(path: CompatibilityManifest.executablePath)
        )
        let info: [String: String] = [
            "CFBundleShortVersionString": "2.5.0",
            "CFBundleVersion": "5814786",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: root.appending(path: "Cyberpunk2077.app/Contents/Info.plist"))
        try Data("{\"buildId\":\"60152051833789151\"}".utf8)
            .write(to: root.appending(path: "Contents/Resources/goggame-1423049311.info"))

        manifest = CompatibilityManifest(
            schema: CompatibilityManifest.schema,
            loaderVersion: "0.1.3",
            target: targetIdentityTarget(),
            metadataSources: .authoritative,
            managedFiles: [
                CompatibilityManagedFile(
                    packagePath: "archive-loader/compatibility/manifest.json",
                    gamePath: "archive-loader/compatibility/manifest.json",
                    sha256: String(repeating: "0", count: 64)
                ),
                CompatibilityManagedFile(
                    packagePath: "archive-loader/red4ext/RED4ext.dylib",
                    gamePath: "red4ext/RED4ext.dylib",
                    sha256: String(repeating: "a", count: 64)
                ),
                CompatibilityManagedFile(
                    packagePath: "archive-loader/red4ext/plugins/TweakXL.dylib",
                    gamePath: "red4ext/plugins/TweakXL.dylib",
                    sha256: String(repeating: "b", count: 64)
                ),
                CompatibilityManagedFile(
                    packagePath: "archive-loader/red4ext/plugins/ArchiveXL.dylib",
                    gamePath: "red4ext/plugins/ArchiveXL.dylib",
                    sha256: String(repeating: "c", count: 64)
                ),
            ],
            frameworkRuntime: FrameworkRuntimeManifest(
                schema: FrameworkRuntimeManifest.schema,
                roles: FrameworkRuntimeRole.required.map(\.rawValue),
                environment: [
                    "DYLD_INSERT_LIBRARIES": FrameworkRuntimeEnvironment(
                        mode: "prepend",
                        paths: ["red4ext/RED4ext.dylib"]
                    ),
                    "DYLD_FORCE_FLAT_NAMESPACE": FrameworkRuntimeEnvironment(
                        mode: "replace",
                        value: "1"
                    ),
                ]
            )
        )
    }

    func output(for command: String) -> String {
        switch command {
        case "lipo": return "arm64"
        case "otool": return "cmd LC_UUID\n    uuid 01234567-89ab-cdef-0123-456789abcdef"
        case "shasum": return String(repeating: "a", count: 64) + "  executable"
        case "codesign": return ""
        default: return ""
        }
    }
}

private func targetIdentityTarget() -> CompatibilityTarget {
    CompatibilityTarget(
        game: "Cyberpunk 2077",
        distribution: "gog",
        platform: "macos",
        architecture: "arm64",
        version: "2.5.0",
        bundleVersion: "5814786",
        gogBuildId: "60152051833789151",
        executable: CompatibilityExecutable(
            path: CompatibilityManifest.executablePath,
            uuid: "01234567-89ab-cdef-0123-456789abcdef",
            sha256: String(repeating: "a", count: 64)
        )
    )
}
