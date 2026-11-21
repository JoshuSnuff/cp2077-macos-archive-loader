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

private func syntheticManifest(managedFiles: [CompatibilityManagedFile]) -> CompatibilityManifest {
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
        managedFiles: managedFiles
    )
}
