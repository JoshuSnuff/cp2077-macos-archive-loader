import CP2077ArchiveCore
import Foundation
import Testing

@Test func packagePathsMustUseTheArchiveLoaderZipNamespace() {
    let manifest = syntheticManifest(
        managedFiles: [
            CompatibilityManagedFile(
                packagePath: "bin/archive-loader",
                gamePath: "archive-loader/bin/archive-loader",
                sha256: syntheticHash
            ),
            CompatibilityManagedFile(
                packagePath: "archive-loader/compatibility/manifest.json",
                gamePath: "archive-loader/compatibility/manifest.json",
                sha256: syntheticHash
            ),
        ]
    )

    #expect(throws: CompatibilityManifestError.self) {
        try manifest.validate()
    }
}

@Test func frameworkRuntimeRequiresEveryNativeRoleMapping() {
    let manifest = syntheticManifest(
        managedFiles: runtimeManagedFiles().filter { $0.gamePath != "red4ext/plugins/ArchiveXL.dylib" },
        frameworkRuntime: frameworkRuntimeManifest()
    )

    #expect(throws: CompatibilityManifestError.self) {
        try manifest.validate()
    }
}

@Test func frameworkRuntimeRejectsDuplicateRoleMappings() {
    let duplicate = CompatibilityManagedFile(
        packagePath: "archive-loader/red4ext/plugins/ArchiveXL-copy.dylib",
        gamePath: "red4ext/plugins/ArchiveXL.dylib",
        sha256: syntheticHash
    )
    let manifest = syntheticManifest(
        managedFiles: runtimeManagedFiles() + [duplicate],
        frameworkRuntime: frameworkRuntimeManifest()
    )

    #expect(throws: CompatibilityManifestError.self) {
        try manifest.validate()
    }
}

@Test func frameworkRuntimeRejectsUnknownEnvironmentFields() {
    let manifest = syntheticManifest(
        managedFiles: runtimeManagedFiles(),
        frameworkRuntime: frameworkRuntimeManifest(
            environment: [
                "DYLD_INSERT_LIBRARIES": FrameworkRuntimeEnvironment(
                    mode: "prepend",
                    paths: ["red4ext/RED4ext.dylib"]
                ),
                "DYLD_FORCE_FLAT_NAMESPACE": FrameworkRuntimeEnvironment(
                    mode: "replace",
                    value: "1"
                ),
                "DYLD_UNKNOWN": FrameworkRuntimeEnvironment(mode: "replace", value: "1"),
            ]
        )
    )

    #expect(throws: CompatibilityManifestError.self) {
        try manifest.validate()
    }
}

@Test func frameworkRuntimeRejectsUnknownNestedEnvironmentFields() throws {
    let json = Data(
        """
        {
          "schema": "archive-loader-framework-runtime/v1",
          "roles": ["red4ext-loader", "tweakxl-plugin", "archivexl-plugin"],
          "environment": {
            "DYLD_INSERT_LIBRARIES": {
              "mode": "prepend",
              "paths": ["red4ext/RED4ext.dylib"],
              "unexpected": true
            },
            "DYLD_FORCE_FLAT_NAMESPACE": {
              "mode": "replace",
              "value": "1"
            }
          }
        }
        """.utf8
    )

    #expect(throws: CompatibilityManifestError.self) {
        try JSONDecoder().decode(FrameworkRuntimeManifest.self, from: json)
    }
}

@Test func frameworkRuntimeRejectsNonNativeDestination() {
    let entries = runtimeManagedFiles().map { entry in
        entry.gamePath == "red4ext/plugins/TweakXL.dylib"
            ? CompatibilityManagedFile(
                packagePath: entry.packagePath,
                gamePath: "red4ext/TweakXL.dylib",
                sha256: entry.sha256
            )
            : entry
    }
    let manifest = syntheticManifest(
        managedFiles: entries,
        frameworkRuntime: frameworkRuntimeManifest()
    )

    #expect(throws: CompatibilityManifestError.self) {
        try manifest.validate()
    }
}

@Test func runtimePackageRejectsPathEscapesAndSymlinks() throws {
    let escaped = syntheticManifest(
        managedFiles: [
            CompatibilityManagedFile(
                packagePath: "archive-loader/../outside.dylib",
                gamePath: "red4ext/RED4ext.dylib",
                sha256: syntheticHash
            ),
            runtimeManagedFiles()[1],
            runtimeManagedFiles()[2],
            runtimeManagedFiles()[3],
        ],
        frameworkRuntime: frameworkRuntimeManifest()
    )
    #expect(throws: CompatibilityManifestError.self) {
        try escaped.validate()
    }

    let fixture = try RuntimePackageFixture(contents: validArm64MachO())
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let target = fixture.root.appending(path: "archive-loader/red4ext/RED4ext.dylib")
    try FileManager.default.removeItem(at: target)
    try FileManager.default.createSymbolicLink(
        at: target,
        withDestinationURL: fixture.root.appending(path: "outside.dylib")
    )
    #expect(throws: CompatibilityManifestError.self) {
        try CompatibilityPackageValidator.validate(
            manifest: fixture.document.manifest,
            packageRoot: fixture.root,
            commandRunner: { _, _ in "" },
            quarantineChecker: { _ in false }
        )
    }
}

@Test("runtime package rejects malformed Mach-O fixtures", arguments: [
    Data("MZ-not-a-mach-o".utf8),
    Data([0xcf, 0xfa]),
    truncatedArm64MachO(),
    headerOnlyArm64MachO(),
    executableArm64MachO(),
    malformedLoadCommandMachO(),
    fatArm64SliceOutOfBounds(),
    fatMachOWithoutArm64(),
])
func runtimePackageRejectsNonArm64MachO(contents: Data) throws {
    let fixture = try RuntimePackageFixture(contents: contents)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    #expect(throws: CompatibilityManifestError.self) {
        try CompatibilityPackageValidator.validate(
            manifest: fixture.document.manifest,
            packageRoot: fixture.root,
            commandRunner: { _, _ in "" },
            quarantineChecker: { _ in false }
        )
    }
}

@Test func runtimePackageAcceptsAValidFatArm64Dylib() throws {
    let fixture = try RuntimePackageFixture(contents: fatArm64Dylib())
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let result = try CompatibilityPackageValidator.validate(
        manifest: fixture.document.manifest,
        packageRoot: fixture.root,
        commandRunner: { _, _ in "" },
        quarantineChecker: { _ in false }
    )
    #expect(result.validatedFiles == fixture.document.manifest.managedFiles)
}

@Test func runtimePackageAcceptsAValidThinArm64Dylib() throws {
    let fixture = try RuntimePackageFixture(contents: validArm64MachO())
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let result = try CompatibilityPackageValidator.validate(
        manifest: fixture.document.manifest,
        packageRoot: fixture.root,
        commandRunner: { _, _ in "" },
        quarantineChecker: { _ in false }
    )
    #expect(result.validatedFiles == fixture.document.manifest.managedFiles)
}

@Test func runtimePackageRequiresExecutableMode() throws {
    let fixture = try RuntimePackageFixture(contents: validArm64MachO())
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let binary = fixture.root.appending(path: "archive-loader/red4ext/RED4ext.dylib")
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: binary.path)

    #expect(throws: CompatibilityManifestError.self) {
        try CompatibilityPackageValidator.validate(
            manifest: fixture.document.manifest,
            packageRoot: fixture.root,
            commandRunner: { _, _ in "" },
            quarantineChecker: { _ in false }
        )
    }
}

@Test func runtimePackageRejectsSigningAndQuarantineFailures() throws {
    let fixture = try RuntimePackageFixture(contents: validArm64MachO())
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    #expect(throws: CompatibilityManifestError.self) {
        try CompatibilityPackageValidator.validate(
            manifest: fixture.document.manifest,
            packageRoot: fixture.root,
            commandRunner: { command, _ in
                if command == "codesign" { throw FixtureFailure.commandFailed }
                return ""
            },
            quarantineChecker: { _ in false }
        )
    }

    #expect(throws: CompatibilityManifestError.self) {
        try CompatibilityPackageValidator.validate(
            manifest: fixture.document.manifest,
            packageRoot: fixture.root,
            commandRunner: { _, _ in "" },
            quarantineChecker: { _ in true }
        )
    }

    #expect(throws: CompatibilityManifestError.self) {
        try CompatibilityPackageValidator.validate(
            manifest: fixture.document.manifest,
            packageRoot: fixture.root,
            commandRunner: { _, _ in "" },
            quarantineChecker: { _ in throw FixtureFailure.quarantineCheckFailed }
        )
    }
}

@Test func defaultQuarantineCheckerSurfacesUnexpectedFilesystemErrors() {
    let missing = FileManager.default.temporaryDirectory
        .appending(path: "compatibility-quarantine-missing-\(UUID().uuidString)")

    #expect(throws: CompatibilityManifestError.self) {
        try CompatibilityPreflight.hasQuarantine(missing)
    }
}

@Test func adHocResigningDoesNotInvalidateTheRuntimeIdentity() {
    let manifest = syntheticManifest(managedFiles: [])
    let target = manifest.target
    let actual = CompatibilityIdentity(
        architecture: target.architecture,
        version: target.version,
        bundleVersion: target.bundleVersion,
        gogBuildId: target.gogBuildId,
        executableUUID: target.executable.uuid,
        executableSHA256: String(repeating: "b", count: 64)
    )

    #expect(CompatibilityIdentityValidator.mismatches(target: target, actual: actual).isEmpty)
}

@Test func codecPreservesTheExactShippedBytesWhenVerifyingTheSelfHash() throws {
    let manifest = syntheticManifest(
        managedFiles: [
            CompatibilityManagedFile(
                packagePath: "archive-loader/bin/archive-loader",
                gamePath: "archive-loader/bin/archive-loader",
                sha256: syntheticHash
            ),
            CompatibilityManagedFile(
                packagePath: "archive-loader/compatibility/manifest.json",
                gamePath: "archive-loader/compatibility/manifest.json",
                sha256: String(repeating: "0", count: 64)
            ),
        ]
    )

    let encoded = try CompatibilityManifestCodec.encode(manifest)
    let document = try CompatibilityManifestDocument(bytes: encoded)

    #expect(encoded.last == 0x0a)
    #expect(document.bytes == encoded)
    #expect(encoded[document.selfHashRange].count == 64)
    #expect(encoded[document.selfHashRange].allSatisfy { byte in
        (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
    })

    var reformatted = encoded
    guard let newline = reformatted.firstIndex(of: 0x0a) else {
        Issue.record("encoded manifest did not contain a newline")
        return
    }
    reformatted[newline] = 0x20
    #expect(throws: CompatibilityManifestError.self) {
        try CompatibilityManifestDocument(bytes: reformatted)
    }
}

@Test func packageValidationHashesSourcesWithoutReadingTargetMetadata() throws {
    let manifest = syntheticManifest(
        managedFiles: [
            CompatibilityManagedFile(
                packagePath: "archive-loader/bin/archive-loader",
                gamePath: "archive-loader/bin/archive-loader",
                sha256: "d47712cceb4c780603026e6325221c1bcff90679ebc076baa51c71ebe796717c"
            ),
            CompatibilityManagedFile(
                packagePath: "archive-loader/compatibility/manifest.json",
                gamePath: "archive-loader/compatibility/manifest.json",
                sha256: String(repeating: "0", count: 64)
            ),
        ]
    )
    let manifestBytes = try CompatibilityManifestCodec.encode(manifest)
    let document = try CompatibilityManifestDocument(bytes: manifestBytes)

    let root = FileManager.default.temporaryDirectory
        .appending(path: "compatibility-manifest-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let binaryURL = root.appending(path: "archive-loader/bin/archive-loader")
    let manifestURL = root.appending(path: "archive-loader/compatibility/manifest.json")
    try FileManager.default.createDirectory(
        at: binaryURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: manifestURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("loader".utf8).write(to: binaryURL)
    try manifestBytes.write(to: manifestURL)

    let result = try CompatibilityPackageValidator.validate(
        manifest: document.manifest,
        packageRoot: root
    )

    #expect(result.validatedFiles == document.manifest.managedFiles)
}

@Test func duplicateManifestSelfEntriesAreRejected() {
    let entry = CompatibilityManagedFile(
        packagePath: "archive-loader/compatibility/manifest.json",
        gamePath: "archive-loader/compatibility/manifest.json",
        sha256: syntheticHash
    )
    let manifest = syntheticManifest(managedFiles: [entry, entry])

    #expect(throws: CompatibilityManifestError.self) {
        try manifest.validate()
    }
}

@Test func managedPathsRejectControlCharacters() {
    let manifest = syntheticManifest(
        managedFiles: [
            CompatibilityManagedFile(
                packagePath: "archive-loader/bin/\u{0000}archive-loader",
                gamePath: "archive-loader/bin/archive-loader",
                sha256: syntheticHash
            ),
            CompatibilityManagedFile(
                packagePath: "archive-loader/compatibility/manifest.json",
                gamePath: "archive-loader/compatibility/manifest.json",
                sha256: syntheticHash
            ),
        ]
    )

    #expect(throws: CompatibilityManifestError.self) {
        try manifest.validate()
    }
}

private let syntheticHash = String(repeating: "a", count: 64)

private func syntheticManifest(
    managedFiles: [CompatibilityManagedFile],
    frameworkRuntime: FrameworkRuntimeManifest? = nil
) -> CompatibilityManifest {
    CompatibilityManifest(
        schema: CompatibilityManifest.schema,
        loaderVersion: "0.1.3",
        target: CompatibilityTarget(
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
                sha256: syntheticHash
            )
        ),
        metadataSources: .authoritative,
        managedFiles: managedFiles,
        frameworkRuntime: frameworkRuntime
    )
}

private func frameworkRuntimeManifest(
    environment: [String: FrameworkRuntimeEnvironment] = [
        "DYLD_INSERT_LIBRARIES": FrameworkRuntimeEnvironment(
            mode: "prepend",
            paths: ["red4ext/RED4ext.dylib"]
        ),
        "DYLD_FORCE_FLAT_NAMESPACE": FrameworkRuntimeEnvironment(
            mode: "replace",
            value: "1"
        ),
    ]
) -> FrameworkRuntimeManifest {
    FrameworkRuntimeManifest(
        schema: FrameworkRuntimeManifest.schema,
        roles: FrameworkRuntimeRole.required.map(\.rawValue),
        environment: environment
    )
}

private func runtimeManagedFiles() -> [CompatibilityManagedFile] {
    [
        CompatibilityManagedFile(
            packagePath: "archive-loader/compatibility/manifest.json",
            gamePath: "archive-loader/compatibility/manifest.json",
            sha256: String(repeating: "0", count: 64)
        ),
        CompatibilityManagedFile(
            packagePath: "archive-loader/red4ext/RED4ext.dylib",
            gamePath: "red4ext/RED4ext.dylib",
            sha256: syntheticHash
        ),
        CompatibilityManagedFile(
            packagePath: "archive-loader/red4ext/plugins/TweakXL.dylib",
            gamePath: "red4ext/plugins/TweakXL.dylib",
            sha256: syntheticHash
        ),
        CompatibilityManagedFile(
            packagePath: "archive-loader/red4ext/plugins/ArchiveXL.dylib",
            gamePath: "red4ext/plugins/ArchiveXL.dylib",
            sha256: syntheticHash
        ),
    ]
}

private enum FixtureFailure: Error {
    case commandFailed
    case quarantineCheckFailed
}

private struct RuntimePackageFixture {
    let root: URL
    let document: CompatibilityManifestDocument

    init(contents: Data) throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "compatibility-runtime-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let rolePaths = [
            "archive-loader/red4ext/RED4ext.dylib",
            "archive-loader/red4ext/plugins/TweakXL.dylib",
            "archive-loader/red4ext/plugins/ArchiveXL.dylib",
        ]
        for path in rolePaths {
            let file = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }

        var manifest = syntheticManifest(
            managedFiles: runtimeManagedFiles(),
            frameworkRuntime: frameworkRuntimeManifest()
        )
        for index in manifest.managedFiles.indices where manifest.managedFiles[index].packagePath != "archive-loader/compatibility/manifest.json" {
            let file = root.appending(path: manifest.managedFiles[index].packagePath)
            manifest.managedFiles[index].sha256 = try Hashes.sha256Hex(ofFileAt: file)
        }
        let bytes = try CompatibilityManifestCodec.encode(manifest)
        let manifestURL = root.appending(path: "archive-loader/compatibility/manifest.json")
        try FileManager.default.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bytes.write(to: manifestURL)
        document = try CompatibilityManifestDocument(bytes: bytes)
    }
}

private func validArm64MachO() -> Data {
    var bytes = Data(repeating: 0, count: 136)
    writeUInt32(0xfeedfacf, at: 0, in: &bytes)
    writeUInt32(0x0100000c, at: 4, in: &bytes)
    writeUInt32(6, at: 12, in: &bytes)
    writeUInt32(2, at: 16, in: &bytes)
    writeUInt32(104, at: 20, in: &bytes)
    writeUInt32(0x19, at: 32, in: &bytes)
    writeUInt32(72, at: 36, in: &bytes)
    bytes.replaceSubrange(40..<46, with: Data("__TEXT".utf8))
    writeUInt64(0, at: 72, in: &bytes)
    writeUInt64(UInt64(bytes.count), at: 80, in: &bytes)
    writeUInt32(0x0d, at: 104, in: &bytes)
    writeUInt32(32, at: 108, in: &bytes)
    writeUInt32(24, at: 112, in: &bytes)
    bytes.replaceSubrange(128..<136, with: Data("fixture\0".utf8))
    return bytes
}

private func truncatedArm64MachO() -> Data {
    var bytes = Data(repeating: 0, count: 24)
    writeUInt32(0xfeedfacf, at: 0, in: &bytes)
    writeUInt32(0x0100000c, at: 4, in: &bytes)
    writeUInt32(6, at: 12, in: &bytes)
    writeUInt32(1, at: 16, in: &bytes)
    writeUInt32(8, at: 20, in: &bytes)
    return bytes
}

private func headerOnlyArm64MachO() -> Data {
    var bytes = Data(repeating: 0, count: 32)
    writeUInt32(0xfeedfacf, at: 0, in: &bytes)
    writeUInt32(0x0100000c, at: 4, in: &bytes)
    writeUInt32(6, at: 12, in: &bytes)
    return bytes
}

private func executableArm64MachO() -> Data {
    var bytes = validArm64MachO()
    writeUInt32(2, at: 12, in: &bytes)
    return bytes
}

private func malformedLoadCommandMachO() -> Data {
    var bytes = Data(repeating: 0, count: 40)
    writeUInt32(0xfeedfacf, at: 0, in: &bytes)
    writeUInt32(0x0100000c, at: 4, in: &bytes)
    writeUInt32(6, at: 12, in: &bytes)
    writeUInt32(1, at: 16, in: &bytes)
    writeUInt32(8, at: 20, in: &bytes)
    writeUInt32(0x0d, at: 32, in: &bytes)
    writeUInt32(4, at: 36, in: &bytes)
    return bytes
}

private func fatArm64SliceOutOfBounds() -> Data {
    var bytes = Data(repeating: 0, count: 28)
    writeBigEndianUInt32(0xcafebabe, at: 0, in: &bytes)
    writeBigEndianUInt32(1, at: 4, in: &bytes)
    writeBigEndianUInt32(0x0100000c, at: 8, in: &bytes)
    writeBigEndianUInt32(0, at: 12, in: &bytes)
    writeBigEndianUInt32(64, at: 16, in: &bytes)
    writeBigEndianUInt32(64, at: 20, in: &bytes)
    return bytes
}

private func fatArm64Dylib() -> Data {
    let slice = validArm64MachO()
    var bytes = Data(repeating: 0, count: 28)
    writeBigEndianUInt32(0xcafebabe, at: 0, in: &bytes)
    writeBigEndianUInt32(1, at: 4, in: &bytes)
    writeBigEndianUInt32(0x0100000c, at: 8, in: &bytes)
    writeBigEndianUInt32(0, at: 12, in: &bytes)
    writeBigEndianUInt32(28, at: 16, in: &bytes)
    writeBigEndianUInt32(UInt32(slice.count), at: 20, in: &bytes)
    bytes.append(slice)
    return bytes
}

private func writeUInt32(_ value: UInt32, at offset: Int, in data: inout Data) {
    data[offset] = UInt8(value & 0xff)
    data[offset + 1] = UInt8((value >> 8) & 0xff)
    data[offset + 2] = UInt8((value >> 16) & 0xff)
    data[offset + 3] = UInt8((value >> 24) & 0xff)
}

private func writeUInt64(_ value: UInt64, at offset: Int, in data: inout Data) {
    for index in 0..<8 {
        data[offset + index] = UInt8((value >> UInt64(index * 8)) & 0xff)
    }
}

private func writeBigEndianUInt32(_ value: UInt32, at offset: Int, in data: inout Data) {
    data[offset] = UInt8((value >> 24) & 0xff)
    data[offset + 1] = UInt8((value >> 16) & 0xff)
    data[offset + 2] = UInt8((value >> 8) & 0xff)
    data[offset + 3] = UInt8(value & 0xff)
}

private func fatMachOWithoutArm64() -> Data {
    var bytes = Data([0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 1])
    bytes.append(Data([0, 0, 0, 7]))
    bytes.append(Data(repeating: 0, count: 12))
    return bytes
}
