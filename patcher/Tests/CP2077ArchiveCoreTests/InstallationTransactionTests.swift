import CP2077ArchiveCore
import Darwin
import Foundation
import Testing

@Suite("Installation transaction and recovery")
struct InstallationTransactionTests {
    @Test func prepareAndStagePersistCompleteVerifiedStateBeforeReplacement() throws {
        let fixture = try TransactionFixture()
        defer { fixture.cleanUp() }
        try fixture.writeGameFile("archive-loader/bin/tool", bytes: "old", mode: 0o640)

        let prepared = try fixture.service.prepare(
            manifestDocument: fixture.document,
            packageRoot: fixture.packageRoot,
            verifiedIdentity: fixture.identity,
            transactionID: "prepare-stage"
        )

        #expect(prepared.phase == .prepared)
        let snapshot = try fixture.service.snapshot(transactionID: prepared.transactionID)
        #expect(snapshot.complete)
        #expect(snapshot.entries.count == fixture.document.manifest.managedFiles.count)
        let existing = try #require(snapshot.entries.first { $0.gamePath == "archive-loader/bin/tool" })
        #expect(existing.wasPresent)
        #expect(existing.mode == 0o640)
        #expect(existing.sha256 == Hashes.sha256Hex(of: Data("old".utf8)))
        let absent = try #require(snapshot.entries.first { $0.gamePath == "archive-loader/share/config.json" })
        #expect(!absent.wasPresent)
        #expect(absent.mode == nil)
        #expect(absent.sha256 == nil)
        #expect(try fixture.readGameFile("archive-loader/bin/tool") == Data("old".utf8))

        let staged = try fixture.service.stage(
            transactionID: prepared.transactionID,
            packageRoot: fixture.packageRoot
        )

        #expect(staged.phase == .staged)
        #expect(try fixture.readGameFile("archive-loader/bin/tool") == Data("old".utf8))
        for mapping in staged.managedMappings {
            let stagedURL = fixture.gameRoot.appending(path: staged.stagingPath)
                .appending(path: "files/\(mapping.gamePath)")
            #expect(FileManager.default.fileExists(atPath: stagedURL.path))
        }
    }

    @Test func commitAtomicallyInstallsEveryManagedFileAndVerifiesCommittedState() throws {
        let fixture = try TransactionFixture()
        defer { fixture.cleanUp() }
        try fixture.writeGameFile("archive-loader/bin/tool", bytes: "old", mode: 0o600)
        try fixture.writeUnrelatedFile(bytes: "keep me")

        let marker = try fixture.service.install(
            manifestDocument: fixture.document,
            packageRoot: fixture.packageRoot,
            verifiedIdentity: fixture.identity,
            transactionID: "successful-install"
        )

        #expect(marker.phase == .committed)
        #expect(try fixture.readGameFile("archive-loader/bin/tool") == Data("new tool".utf8))
        #expect(try fixture.readGameFile("archive-loader/share/config.json") == Data("new config".utf8))
        #expect(try fixture.readUnrelatedFile() == Data("keep me".utf8))
        #expect(try fixture.service.verifyCommittedTransactions().map(\.transactionID) == ["successful-install"])
        #expect(!FileManager.default.fileExists(
            atPath: fixture.gameRoot.appending(path: marker.stagingPath).path
        ))
        #expect(FileManager.default.fileExists(
            atPath: fixture.gameRoot.appending(path: marker.snapshotPath).path
        ))
    }

    @Test func replacementFailureRollsBackPresentAndAbsentFilesIncludingModes() throws {
        let fixture = try TransactionFixture()
        defer { fixture.cleanUp() }
        try fixture.writeGameFile("archive-loader/bin/tool", bytes: "old", mode: 0o640)
        try fixture.writeUnrelatedFile(bytes: "keep me")
        var replacements = 0

        #expect(throws: InstallationTransactionError.self) {
            _ = try fixture.service.install(
                manifestDocument: fixture.document,
                packageRoot: fixture.packageRoot,
                verifiedIdentity: fixture.identity,
                transactionID: "failed-install",
                beforeReplacing: { _ in
                    replacements += 1
                    if replacements == 2 {
                        throw FixtureFailure.stop
                    }
                }
            )
        }

        let marker = try fixture.service.marker(transactionID: "failed-install")
        #expect(marker.phase == .rolledBack)
        #expect(try fixture.readGameFile("archive-loader/bin/tool") == Data("old".utf8))
        #expect(try fixture.mode(ofGamePath: "archive-loader/bin/tool") == 0o640)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.gameRoot.appending(path: "archive-loader/share/config.json").path
        ))
        #expect(try fixture.readUnrelatedFile() == Data("keep me".utf8))
    }

    @Test func startupRecoveryRollsBackAnInterruptedReplacingTransaction() throws {
        let fixture = try TransactionFixture()
        defer { fixture.cleanUp() }
        try fixture.writeGameFile("archive-loader/bin/tool", bytes: "old", mode: 0o640)
        let prepared = try fixture.service.prepare(
            manifestDocument: fixture.document,
            packageRoot: fixture.packageRoot,
            verifiedIdentity: fixture.identity,
            transactionID: "interrupted"
        )
        _ = try fixture.service.stage(transactionID: prepared.transactionID, packageRoot: fixture.packageRoot)
        var interrupted = try fixture.service.marker(transactionID: prepared.transactionID)
        interrupted.phase = .replacing
        try fixture.replaceGameFileFromPackage("archive-loader/bin/tool")
        try fixture.writeMarker(interrupted)

        let recovered = try fixture.service.recoverAtStartup()

        #expect(recovered.map(\.transactionID) == ["interrupted"])
        #expect(recovered.first?.phase == .rolledBack)
        #expect(try fixture.readGameFile("archive-loader/bin/tool") == Data("old".utf8))
        #expect(try fixture.mode(ofGamePath: "archive-loader/bin/tool") == 0o640)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.gameRoot.appending(path: "archive-loader/share/config.json").path
        ))
    }

    @Test func committedVerificationFailsClosedWhenInstalledContentDrifts() throws {
        let fixture = try TransactionFixture()
        defer { fixture.cleanUp() }
        _ = try fixture.service.install(
            manifestDocument: fixture.document,
            packageRoot: fixture.packageRoot,
            verifiedIdentity: fixture.identity,
            transactionID: "drifted"
        )
        try fixture.writeGameFile("archive-loader/bin/tool", bytes: "tampered", mode: 0o755)

        #expect(throws: InstallationTransactionError.self) {
            _ = try fixture.service.recoverAtStartup()
        }
        #expect(try fixture.service.marker(transactionID: "drifted").phase == .committed)
    }

    @Test func startupAcceptsTheCurrentCommitAfterAnUpgradeRetainsOlderAuditRecords() throws {
        let fixture = try TransactionFixture()
        defer { fixture.cleanUp() }
        _ = try fixture.service.install(
            manifestDocument: fixture.document,
            packageRoot: fixture.packageRoot,
            verifiedIdentity: fixture.identity,
            transactionID: "old-release"
        )
        let upgradedDocument = try fixture.replacePackageContents(
            tool: "upgraded tool",
            config: "upgraded config"
        )

        _ = try fixture.service.install(
            manifestDocument: upgradedDocument,
            packageRoot: fixture.packageRoot,
            verifiedIdentity: fixture.identity,
            transactionID: "new-release"
        )

        #expect(try fixture.service.recoverAtStartup().isEmpty)
        #expect(try fixture.service.verifyCommittedTransactions().map(\.transactionID) == ["new-release"])
        #expect(try fixture.service.marker(transactionID: "old-release").phase == .committed)
        #expect(try fixture.readGameFile("archive-loader/bin/tool") == Data("upgraded tool".utf8))
    }

    @Test func corruptSnapshotPreventsRecoveryAndLeavesEvidenceIntact() throws {
        let fixture = try TransactionFixture()
        defer { fixture.cleanUp() }
        try fixture.writeGameFile("archive-loader/bin/tool", bytes: "old", mode: 0o640)
        let marker = try fixture.service.prepare(
            manifestDocument: fixture.document,
            packageRoot: fixture.packageRoot,
            verifiedIdentity: fixture.identity,
            transactionID: "corrupt-snapshot"
        )
        let snapshot = try fixture.service.snapshot(transactionID: marker.transactionID)
        let entry = try #require(snapshot.entries.first { $0.wasPresent })
        try Data("corrupt".utf8).write(
            to: fixture.gameRoot.appending(path: marker.snapshotPath)
                .appending(path: "files/\(entry.gamePath)")
        )

        #expect(throws: InstallationTransactionError.self) {
            _ = try fixture.service.recoverAtStartup()
        }
        #expect(FileManager.default.fileExists(
            atPath: fixture.gameRoot.appending(path: marker.snapshotPath).path
        ))
        #expect(FileManager.default.fileExists(
            atPath: fixture.service.markerURL(transactionID: marker.transactionID).path
        ))
        #expect(try fixture.readGameFile("archive-loader/bin/tool") == Data("old".utf8))
    }

    @Test func identityMismatchIsRejectedBeforeTransactionStateIsWritten() throws {
        let fixture = try TransactionFixture()
        defer { fixture.cleanUp() }
        let wrongIdentity = CompatibilityIdentity(
            architecture: fixture.identity.architecture,
            version: "0.0.0",
            bundleVersion: fixture.identity.bundleVersion,
            gogBuildId: fixture.identity.gogBuildId,
            executableUUID: fixture.identity.executableUUID,
            executableSHA256: fixture.identity.executableSHA256
        )

        #expect(throws: CompatibilityManifestError.self) {
            _ = try fixture.service.prepare(
                manifestDocument: fixture.document,
                packageRoot: fixture.packageRoot,
                verifiedIdentity: wrongIdentity,
                transactionID: "wrong-identity"
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: fixture.service.markerURL(transactionID: "wrong-identity").path
        ))
    }
}

private enum FixtureFailure: Error {
    case stop
}

private struct TransactionFixture {
    let root: URL
    let gameRoot: URL
    let packageRoot: URL
    let document: CompatibilityManifestDocument
    let identity: CompatibilityIdentity
    let service: InstallationTransactionService

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "install-transaction-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        gameRoot = root.appending(path: "Game", directoryHint: .isDirectory)
        packageRoot = root.appending(path: "Package", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: gameRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)

        let packageFiles: [(String, Data, UInt16)] = [
            ("archive-loader/bin/tool", Data("new tool".utf8), 0o755),
            ("archive-loader/share/config.json", Data("new config".utf8), 0o644),
        ]
        for (path, bytes, mode) in packageFiles {
            let url = packageRoot.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try bytes.write(to: url)
            guard chmod(url.path, mode_t(mode)) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
        }

        let selfPath = "archive-loader/compatibility/manifest.json"
        var managed = packageFiles.map { path, bytes, _ in
            CompatibilityManagedFile(
                packagePath: path,
                gamePath: path,
                sha256: Hashes.sha256Hex(of: bytes)
            )
        }
        managed.append(CompatibilityManagedFile(
            packagePath: selfPath,
            gamePath: selfPath,
            sha256: String(repeating: "0", count: 64)
        ))
        let manifest = CompatibilityManifest(
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
                    uuid: "12345678-1234-1234-1234-123456789abc",
                    sha256: String(repeating: "a", count: 64)
                )
            ),
            metadataSources: .authoritative,
            managedFiles: managed
        )
        let manifestBytes = try CompatibilityManifestCodec.encode(manifest)
        let manifestURL = packageRoot.appending(path: selfPath)
        try FileManager.default.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try manifestBytes.write(to: manifestURL)
        document = try CompatibilityManifestDocument(bytes: manifestBytes)
        identity = CompatibilityIdentity(
            architecture: document.manifest.target.architecture,
            version: document.manifest.target.version,
            bundleVersion: document.manifest.target.bundleVersion,
            gogBuildId: document.manifest.target.gogBuildId,
            executableUUID: document.manifest.target.executable.uuid,
            executableSHA256: document.manifest.target.executable.sha256
        )
        service = InstallationTransactionService(gameRoot: gameRoot)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeGameFile(_ path: String, bytes: String, mode: UInt16) throws {
        let url = gameRoot.appending(path: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(bytes.utf8).write(to: url)
        guard chmod(url.path, mode_t(mode)) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func readGameFile(_ path: String) throws -> Data {
        try Data(contentsOf: gameRoot.appending(path: path))
    }

    func mode(ofGamePath path: String) throws -> UInt16 {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: gameRoot.appending(path: path).path
        )
        return UInt16(truncating: try #require(attributes[.posixPermissions] as? NSNumber))
    }

    func writeUnrelatedFile(bytes: String) throws {
        try writeGameFile("mods/unrelated.archive", bytes: bytes, mode: 0o644)
    }

    func readUnrelatedFile() throws -> Data {
        try readGameFile("mods/unrelated.archive")
    }

    func replaceGameFileFromPackage(_ path: String) throws {
        let destination = gameRoot.appending(path: path)
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: packageRoot.appending(path: path), to: destination)
    }

    func replacePackageContents(tool: String, config: String) throws -> CompatibilityManifestDocument {
        let replacements = [
            "archive-loader/bin/tool": Data(tool.utf8),
            "archive-loader/share/config.json": Data(config.utf8),
        ]
        var manifest = document.manifest
        for index in manifest.managedFiles.indices {
            let path = manifest.managedFiles[index].packagePath
            if let bytes = replacements[path] {
                try bytes.write(to: packageRoot.appending(path: path))
                manifest.managedFiles[index].sha256 = Hashes.sha256Hex(of: bytes)
            } else if path == "archive-loader/compatibility/manifest.json" {
                manifest.managedFiles[index].sha256 = String(repeating: "0", count: 64)
            }
        }
        let bytes = try CompatibilityManifestCodec.encode(manifest)
        try bytes.write(to: packageRoot.appending(path: "archive-loader/compatibility/manifest.json"))
        return try CompatibilityManifestDocument(bytes: bytes)
    }

    func writeMarker(_ marker: InstallationTransactionMarker) throws {
        let data = try JSONEncoder().encode(marker)
        try data.write(to: service.markerURL(transactionID: marker.transactionID), options: .atomic)
    }
}
