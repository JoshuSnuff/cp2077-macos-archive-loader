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

    @Test func startupRecoveryRetiresAPublishedMarkerBeforeSnapshotCreation() throws {
        let fixture = try TransactionFixture()
        defer { fixture.cleanUp() }
        try fixture.writeGameFile("archive-loader/bin/tool", bytes: "old", mode: 0o640)

        #expect(throws: FixtureFailure.self) {
            _ = try fixture.service.prepare(
                manifestDocument: fixture.document,
                packageRoot: fixture.packageRoot,
                verifiedIdentity: fixture.identity,
                transactionID: "snapshot-boundary",
                afterMarkerPublished: {
                    throw FixtureFailure.stop
                }
            )
        }

        let published = try fixture.service.marker(transactionID: "snapshot-boundary")
        #expect(published.phase == .snapshotting)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.gameRoot.appending(path: published.snapshotPath).path
        ))

        let recovered = try fixture.service.recoverAtStartup()

        #expect(recovered.map(\.transactionID) == ["snapshot-boundary"])
        #expect(try fixture.service.marker(transactionID: "snapshot-boundary").phase == .rolledBack)
        #expect(try fixture.readGameFile("archive-loader/bin/tool") == Data("old".utf8))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.gameRoot.appending(path: published.snapshotPath).path
        ))
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

    @Test func installOverExistingFrameworkTreeAndRemovalPreserveUnrelatedFiles() throws {
        let fixture = try TransactionFixture()
        defer { fixture.cleanUp() }
        try fixture.writeGameFile("red4ext/RED4ext.dylib", bytes: "existing runtime", mode: 0o755)
        try fixture.writeUnrelatedFile(bytes: "keep me")

        let frameworkDocument = try fixture.frameworkDocument(runtime: "new runtime")
        let marker = try fixture.service.install(
            manifestDocument: frameworkDocument,
            packageRoot: fixture.packageRoot,
            verifiedIdentity: fixture.identity,
            transactionID: "framework-install"
        )

        #expect(marker.phase == .committed)
        #expect(try fixture.readGameFile("red4ext/RED4ext.dylib") == Data("new runtime".utf8))
        #expect(try fixture.readUnrelatedFile() == Data("keep me".utf8))

        let removed = try fixture.service.removeCommitted(transactionID: marker.transactionID)

        #expect(removed.phase == .rolledBack)
        #expect(try fixture.readGameFile("red4ext/RED4ext.dylib") == Data("existing runtime".utf8))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.gameRoot.appending(path: "archive-loader/bin/tool").path
        ))
        #expect(try fixture.readUnrelatedFile() == Data("keep me".utf8))
        #expect(try fixture.service.inspect().current == nil)
    }

    @Test func upgradeAndDowngradeRestoreThePreviousFrameworkGeneration() throws {
        let fixture = try TransactionFixture()
        defer { fixture.cleanUp() }
        try fixture.writeGameFile("red4ext/RED4ext.dylib", bytes: "legacy runtime", mode: 0o755)

        let first = try fixture.service.install(
            manifestDocument: try fixture.frameworkDocument(runtime: "runtime v1"),
            packageRoot: fixture.packageRoot,
            verifiedIdentity: fixture.identity,
            transactionID: "runtime-v1"
        )
        let second = try fixture.service.install(
            manifestDocument: try fixture.frameworkDocument(runtime: "runtime v2"),
            packageRoot: fixture.packageRoot,
            verifiedIdentity: fixture.identity,
            transactionID: "runtime-v2"
        )

        #expect(first.phase == .committed)
        #expect(second.phase == .committed)
        #expect(try fixture.readGameFile("red4ext/RED4ext.dylib") == Data("runtime v2".utf8))

        _ = try fixture.service.removeCommitted(transactionID: second.transactionID)

        #expect(try fixture.readGameFile("red4ext/RED4ext.dylib") == Data("runtime v1".utf8))
        #expect(try fixture.service.marker(transactionID: first.transactionID).phase == .committed)
        #expect(try fixture.service.verifyCommittedTransactions().map(\.transactionID) == ["runtime-v1"])
    }

    @Test func startupRecoveryRollsBackPreparedAndStagedFrameworkTransactions() throws {
        let fixture = try TransactionFixture()
        defer { fixture.cleanUp() }
        try fixture.writeGameFile("red4ext/RED4ext.dylib", bytes: "old runtime", mode: 0o755)
        let document = try fixture.frameworkDocument(runtime: "new runtime")

        let prepared = try fixture.service.prepare(
            manifestDocument: document,
            packageRoot: fixture.packageRoot,
            verifiedIdentity: fixture.identity,
            transactionID: "prepared-framework"
        )
        #expect(prepared.phase == .prepared)
        #expect(try fixture.service.recoverAtStartup().map(\.transactionID) == ["prepared-framework"])
        #expect(try fixture.service.marker(transactionID: prepared.transactionID).phase == .rolledBack)
        #expect(try fixture.readGameFile("red4ext/RED4ext.dylib") == Data("old runtime".utf8))

        let staged = try fixture.service.prepare(
            manifestDocument: document,
            packageRoot: fixture.packageRoot,
            verifiedIdentity: fixture.identity,
            transactionID: "staged-framework"
        )
        _ = try fixture.service.stage(
            transactionID: staged.transactionID,
            packageRoot: fixture.packageRoot
        )
        #expect(try fixture.service.marker(transactionID: staged.transactionID).phase == .staged)
        #expect(try fixture.service.recoverAtStartup().map(\.transactionID) == ["staged-framework"])
        #expect(try fixture.service.marker(transactionID: staged.transactionID).phase == .rolledBack)
        #expect(try fixture.readGameFile("red4ext/RED4ext.dylib") == Data("old runtime".utf8))
    }

    @Test func inspectReportsInterruptedTransactionsAndMigratesCompatibilityMarkerAsGenerationZero() throws {
        let fixture = try TransactionFixture()
        defer { fixture.cleanUp() }

        try fixture.installPackageAsCurrentCompatibilityMarker()
        let generationZero = try fixture.service.inspect()

        #expect(generationZero.interrupted.isEmpty)
        #expect(generationZero.committed.isEmpty)
        #expect(generationZero.generationZero?.transactionID == "generation-0")
        #expect(generationZero.current?.transactionID == "generation-0")
        #expect(!FileManager.default.fileExists(
            atPath: fixture.service.markerURL(transactionID: "generation-0").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.gameRoot.appending(path: "archive-loader/runtime/active").path
        ))

        let prepared = try fixture.service.prepare(
            manifestDocument: fixture.document,
            packageRoot: fixture.packageRoot,
            verifiedIdentity: fixture.identity,
            transactionID: "inspect-interrupted"
        )
        let interrupted = try fixture.service.inspect()

        #expect(interrupted.interrupted.map(\.transactionID) == [prepared.transactionID])
        #expect(interrupted.current == nil)
        #expect(try fixture.service.marker(transactionID: prepared.transactionID).phase == .prepared)
    }

    @Test func removalIntentSurvivesInterruptionAndRepeatedRemovalIsIdempotent() throws {
        let fixture = try TransactionFixture()
        defer { fixture.cleanUp() }
        try fixture.writeUnrelatedFile(bytes: "keep me")
        let marker = try fixture.service.install(
            manifestDocument: try fixture.frameworkDocument(runtime: "new runtime"),
            packageRoot: fixture.packageRoot,
            verifiedIdentity: fixture.identity,
            transactionID: "removal-interrupted"
        )
        var mutations = 0

        #expect(throws: FixtureFailure.self) {
            _ = try fixture.service.removeCommitted(
                transactionID: marker.transactionID,
                beforeRemoving: { _ in
                    if mutations == 0 {
                        #expect(try fixture.service.marker(
                            transactionID: marker.transactionID
                        ).phase == .removing)
                    }
                    mutations += 1
                    if mutations == 2 {
                        throw FixtureFailure.stop
                    }
                }
            )
        }
        #expect(try fixture.service.marker(transactionID: marker.transactionID).phase == .removing)

        let recovered = try fixture.service.recoverAtStartup()

        #expect(recovered.map(\.transactionID) == [marker.transactionID])
        #expect(try fixture.service.marker(transactionID: marker.transactionID).phase == .rolledBack)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.gameRoot.appending(path: "red4ext/RED4ext.dylib").path
        ))
        #expect(try fixture.readUnrelatedFile() == Data("keep me".utf8))

        let repeated = try fixture.service.removeCommitted(transactionID: marker.transactionID)
        #expect(repeated.phase == .rolledBack)
        #expect(try fixture.service.inspect().current == nil)
    }

    @Test func historicalRolledBackSnapshotsDoNotValidateAgainstTheCurrentTree() throws {
        let fixture = try TransactionFixture()
        defer { fixture.cleanUp() }

        _ = try fixture.service.install(
            manifestDocument: try fixture.frameworkDocument(runtime: "runtime v1"),
            packageRoot: fixture.packageRoot,
            verifiedIdentity: fixture.identity,
            transactionID: "z-v1"
        )
        let second = try fixture.service.install(
            manifestDocument: try fixture.frameworkDocument(runtime: "runtime v2"),
            packageRoot: fixture.packageRoot,
            verifiedIdentity: fixture.identity,
            transactionID: "a-v2"
        )
        _ = try fixture.service.removeCommitted(transactionID: second.transactionID)
        _ = try fixture.service.install(
            manifestDocument: try fixture.frameworkDocument(runtime: "runtime v3"),
            packageRoot: fixture.packageRoot,
            verifiedIdentity: fixture.identity,
            transactionID: "m-v3"
        )

        _ = try fixture.service.recoverAtStartup()

        #expect(try fixture.readGameFile("red4ext/RED4ext.dylib") == Data("runtime v3".utf8))
        #expect(try fixture.service.marker(transactionID: second.transactionID).phase == .rolledBack)
        #expect(try fixture.service.verifyCommittedTransactions().map(\.transactionID) == ["m-v3"])
    }

    @Test func lineageSelectsCurrentGenerationWhenIDsSortInReverseOrder() throws {
        let fixture = try TransactionFixture()
        defer { fixture.cleanUp() }
        let document = try fixture.frameworkDocument(runtime: "identical runtime")

        let first = try fixture.service.install(
            manifestDocument: document,
            packageRoot: fixture.packageRoot,
            verifiedIdentity: fixture.identity,
            transactionID: "z-first"
        )
        let second = try fixture.service.install(
            manifestDocument: document,
            packageRoot: fixture.packageRoot,
            verifiedIdentity: fixture.identity,
            transactionID: "a-second"
        )

        #expect(first.generation < second.generation)
        #expect(second.parentTransactionID == first.transactionID)
        #expect(throws: InstallationTransactionError.self) {
            _ = try fixture.service.removeCommitted(transactionID: first.transactionID)
        }
        #expect(try fixture.service.marker(transactionID: second.transactionID).phase == .committed)

        _ = try fixture.service.removeCommitted(transactionID: second.transactionID)
        #expect(try fixture.service.marker(transactionID: second.transactionID).phase == .rolledBack)
    }

    @Test func legacyIndependentCommittedMarkersSelectTheUniqueLiveContentMatch() throws {
        let fixture = try TransactionFixture()
        defer { fixture.cleanUp() }

        let first = try fixture.service.install(
            manifestDocument: try fixture.frameworkDocument(runtime: "legacy runtime v1"),
            packageRoot: fixture.packageRoot,
            verifiedIdentity: fixture.identity,
            transactionID: "legacy-v1"
        )
        let second = try fixture.service.install(
            manifestDocument: try fixture.frameworkDocument(runtime: "legacy runtime v2"),
            packageRoot: fixture.packageRoot,
            verifiedIdentity: fixture.identity,
            transactionID: "legacy-v2"
        )
        try fixture.writeLegacyMarker(first)
        try fixture.writeLegacyMarker(second)

        #expect(try fixture.service.inspect().current?.transactionID == second.transactionID)
        #expect(try fixture.service.verifyCommittedTransactions().map(\.transactionID) == [second.transactionID])
    }

    @Test func legacyIndependentCommittedMarkersRemainAmbiguousWhenLiveContentMatchesBoth() throws {
        let fixture = try TransactionFixture()
        defer { fixture.cleanUp() }
        let document = try fixture.frameworkDocument(runtime: "identical legacy runtime")

        let first = try fixture.service.install(
            manifestDocument: document,
            packageRoot: fixture.packageRoot,
            verifiedIdentity: fixture.identity,
            transactionID: "legacy-a"
        )
        let second = try fixture.service.install(
            manifestDocument: document,
            packageRoot: fixture.packageRoot,
            verifiedIdentity: fixture.identity,
            transactionID: "legacy-b"
        )
        try fixture.writeLegacyMarker(first)
        try fixture.writeLegacyMarker(second)

        do {
            _ = try fixture.service.inspect()
            Issue.record("expected ambiguous legacy committed markers to fail closed")
        } catch let error as InstallationTransactionError {
            guard case let .corruptMarker(reason) = error else {
                Issue.record("expected corruptMarker, got \(error)")
                return
            }
            #expect(reason.contains("ambiguous"))
        }
    }

    @Test func modernForkedCommittedMarkersRemainAmbiguousEvenWhenOneMatchesLiveContent() throws {
        let fixture = try TransactionFixture()
        defer { fixture.cleanUp() }

        let root = try fixture.service.install(
            manifestDocument: try fixture.frameworkDocument(runtime: "fork root runtime"),
            packageRoot: fixture.packageRoot,
            verifiedIdentity: fixture.identity,
            transactionID: "fork-root"
        )
        let firstBranch = try fixture.service.install(
            manifestDocument: try fixture.frameworkDocument(runtime: "first branch runtime"),
            packageRoot: fixture.packageRoot,
            verifiedIdentity: fixture.identity,
            transactionID: "fork-a"
        )
        let secondBranch = try fixture.service.install(
            manifestDocument: try fixture.frameworkDocument(runtime: "second branch runtime"),
            packageRoot: fixture.packageRoot,
            verifiedIdentity: fixture.identity,
            transactionID: "fork-b"
        )
        let forkedBranch = InstallationTransactionMarker(
            transactionID: secondBranch.transactionID,
            phase: secondBranch.phase,
            manifestSelfHash: secondBranch.manifestSelfHash,
            targetIdentity: secondBranch.targetIdentity,
            sourcePackageHashes: secondBranch.sourcePackageHashes,
            snapshotPath: secondBranch.snapshotPath,
            stagingPath: secondBranch.stagingPath,
            managedMappings: secondBranch.managedMappings,
            generation: firstBranch.generation,
            parentTransactionID: root.transactionID
        )
        try fixture.writeMarker(forkedBranch)

        do {
            _ = try fixture.service.inspect()
            Issue.record("expected modern forked committed markers to fail closed")
        } catch let error as InstallationTransactionError {
            guard case let .corruptMarker(reason) = error else {
                Issue.record("expected corruptMarker, got \(error)")
                return
            }
            #expect(reason.contains("ambiguous"))
        }
    }

    @Test func explicitlyEncodedGenerationZeroMarkersRemainAmbiguousWhenOneMatchesLiveContent() throws {
        let fixture = try TransactionFixture()
        defer { fixture.cleanUp() }

        let first = try fixture.service.install(
            manifestDocument: try fixture.frameworkDocument(runtime: "explicit generation zero v1"),
            packageRoot: fixture.packageRoot,
            verifiedIdentity: fixture.identity,
            transactionID: "explicit-zero-v1"
        )
        let second = try fixture.service.install(
            manifestDocument: try fixture.frameworkDocument(runtime: "explicit generation zero v2"),
            packageRoot: fixture.packageRoot,
            verifiedIdentity: fixture.identity,
            transactionID: "explicit-zero-v2"
        )
        try fixture.writeMarker(InstallationTransactionMarker(
            transactionID: first.transactionID,
            phase: first.phase,
            manifestSelfHash: first.manifestSelfHash,
            targetIdentity: first.targetIdentity,
            sourcePackageHashes: first.sourcePackageHashes,
            snapshotPath: first.snapshotPath,
            stagingPath: first.stagingPath,
            managedMappings: first.managedMappings,
            generation: 0
        ))
        try fixture.writeMarker(InstallationTransactionMarker(
            transactionID: second.transactionID,
            phase: second.phase,
            manifestSelfHash: second.manifestSelfHash,
            targetIdentity: second.targetIdentity,
            sourcePackageHashes: second.sourcePackageHashes,
            snapshotPath: second.snapshotPath,
            stagingPath: second.stagingPath,
            managedMappings: second.managedMappings,
            generation: 0
        ))

        do {
            _ = try fixture.service.inspect()
            Issue.record("expected explicitly encoded generation-zero markers to fail closed")
        } catch let error as InstallationTransactionError {
            guard case let .corruptMarker(reason) = error else {
                Issue.record("expected corruptMarker, got \(error)")
                return
            }
            #expect(reason.contains("ambiguous"))
        }
    }

    @Test func legacyIndependentCommittedMarkersFailClosedWhenNoLeafMatchesLiveContent() throws {
        let fixture = try TransactionFixture()
        defer { fixture.cleanUp() }

        let first = try fixture.service.install(
            manifestDocument: try fixture.frameworkDocument(runtime: "legacy runtime v1"),
            packageRoot: fixture.packageRoot,
            verifiedIdentity: fixture.identity,
            transactionID: "legacy-no-match-v1"
        )
        let second = try fixture.service.install(
            manifestDocument: try fixture.frameworkDocument(runtime: "legacy runtime v2"),
            packageRoot: fixture.packageRoot,
            verifiedIdentity: fixture.identity,
            transactionID: "legacy-no-match-v2"
        )
        try fixture.writeLegacyMarker(first)
        try fixture.writeLegacyMarker(second)
        try fixture.writeGameFile(
            "red4ext/RED4ext.dylib",
            bytes: "unrecorded live runtime",
            mode: 0o755
        )

        do {
            _ = try fixture.service.inspect()
            Issue.record("expected legacy markers with no live-content match to fail closed")
        } catch let error as InstallationTransactionError {
            guard case let .corruptMarker(reason) = error else {
                Issue.record("expected corruptMarker, got \(error)")
                return
            }
            #expect(reason.contains("no leaf matches live content"))
        }
    }

    @Test func generationZeroHasAnExplicitSafeRemovalPath() throws {
        let fixture = try TransactionFixture()
        defer { fixture.cleanUp() }
        try fixture.installPackageAsCurrentCompatibilityMarker()
        try fixture.writeUnrelatedFile(bytes: "keep me")

        let removed = try fixture.service.removeCommitted(transactionID: "generation-0")

        #expect(removed.transactionID == "generation-0")
        #expect(removed.phase == .rolledBack)
        for entry in fixture.document.manifest.managedFiles {
            #expect(!FileManager.default.fileExists(
                atPath: fixture.gameRoot.appending(path: entry.gamePath).path
            ))
        }
        #expect(try fixture.readUnrelatedFile() == Data("keep me".utf8))

        let repeated = try fixture.service.removeCommitted(transactionID: "generation-0")
        #expect(repeated.phase == .rolledBack)
    }

    @Test func inspectReportsPartialReplacementWithoutValidatingGenerationZero() throws {
        let fixture = try TransactionFixture()
        defer { fixture.cleanUp() }
        try fixture.installPackageAsCurrentCompatibilityMarker()
        let prepared = try fixture.service.prepare(
            manifestDocument: fixture.document,
            packageRoot: fixture.packageRoot,
            verifiedIdentity: fixture.identity,
            transactionID: "partial-replacement"
        )
        _ = try fixture.service.stage(
            transactionID: prepared.transactionID,
            packageRoot: fixture.packageRoot
        )
        var replacing = try fixture.service.marker(transactionID: prepared.transactionID)
        replacing.phase = .replacing
        try fixture.replaceGameFileFromPackage("archive-loader/bin/tool")
        try fixture.writeMarker(replacing)

        let inspection = try fixture.service.inspect()

        #expect(inspection.interrupted.map(\.transactionID) == [prepared.transactionID])
        #expect(inspection.generationZero == nil)
        #expect(inspection.current == nil)
        #expect(try fixture.service.marker(transactionID: prepared.transactionID).phase == .replacing)
    }

    @Test func inspectReportsAnInterruptedOrdinaryRemovalBeforeValidatingTheParentTree() throws {
        let fixture = try TransactionFixture()
        defer { fixture.cleanUp() }
        let marker = try fixture.service.install(
            manifestDocument: try fixture.frameworkDocument(runtime: "new runtime"),
            packageRoot: fixture.packageRoot,
            verifiedIdentity: fixture.identity,
            transactionID: "ordinary-removal-inspect"
        )
        var mutations = 0

        #expect(throws: FixtureFailure.self) {
            _ = try fixture.service.removeCommitted(
                transactionID: marker.transactionID,
                beforeRemoving: { _ in
                    if mutations == 0 {
                        #expect(try fixture.service.marker(
                            transactionID: marker.transactionID
                        ).phase == .removing)
                    }
                    mutations += 1
                    if mutations == 2 {
                        throw FixtureFailure.stop
                    }
                }
            )
        }

        let inspection = try fixture.service.inspect()

        #expect(inspection.interrupted.map(\.transactionID) == [marker.transactionID])
        #expect(inspection.generationZero == nil)
        #expect(inspection.current == nil)
        _ = try fixture.service.recoverAtStartup()
    }

    @Test func inspectReportsInterruptedGenerationZeroRemovalBeforeCompletion() throws {
        let fixture = try TransactionFixture()
        defer { fixture.cleanUp() }
        try fixture.installPackageAsCurrentCompatibilityMarker()

        #expect(throws: FixtureFailure.self) {
            _ = try fixture.service.removeCommitted(
                transactionID: "generation-0",
                beforeRemoving: { _ in
                    #expect(try fixture.service.marker(
                        transactionID: "generation-0"
                    ).phase == .removing)
                    throw FixtureFailure.stop
                }
            )
        }

        let inspection = try fixture.service.inspect()

        #expect(inspection.interrupted.map(\.transactionID) == ["generation-0"])
        #expect(inspection.generationZero == nil)
        #expect(inspection.current == nil)
        _ = try fixture.service.recoverAtStartup()
        #expect(!FileManager.default.fileExists(
            atPath: fixture.gameRoot.appending(path: "archive-loader/compatibility/manifest.json").path
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

    func frameworkDocument(runtime: String) throws -> CompatibilityManifestDocument {
        let packagePath = "archive-loader/red4ext/RED4ext.dylib"
        let packageURL = packageRoot.appending(path: packagePath)
        let bytes = Data(runtime.utf8)
        try FileManager.default.createDirectory(
            at: packageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bytes.write(to: packageURL)
        chmod(packageURL.path, mode_t(0o755))

        var manifest = document.manifest
        manifest.managedFiles.append(CompatibilityManagedFile(
            packagePath: packagePath,
            gamePath: "red4ext/RED4ext.dylib",
            sha256: Hashes.sha256Hex(of: bytes)
        ))
        let manifestBytes = try CompatibilityManifestCodec.encode(manifest)
        try manifestBytes.write(to: packageRoot.appending(path: "archive-loader/compatibility/manifest.json"))
        return try CompatibilityManifestDocument(bytes: manifestBytes)
    }

    func installPackageAsCurrentCompatibilityMarker() throws {
        for entry in document.manifest.managedFiles {
            let source = packageRoot.appending(path: entry.packagePath)
            let destination = gameRoot.appending(path: entry.gamePath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    func writeMarker(_ marker: InstallationTransactionMarker) throws {
        let data = try JSONEncoder().encode(marker)
        try data.write(to: service.markerURL(transactionID: marker.transactionID), options: .atomic)
    }

    func writeLegacyMarker(_ marker: InstallationTransactionMarker) throws {
        guard var object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(marker)
        ) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        object.removeValue(forKey: "generation")
        object.removeValue(forKey: "parentTransactionID")
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: service.markerURL(transactionID: marker.transactionID), options: .atomic)
    }
}
