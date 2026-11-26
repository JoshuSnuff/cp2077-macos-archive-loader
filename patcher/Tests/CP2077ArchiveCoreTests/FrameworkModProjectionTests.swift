import CP2077ArchiveCore
import Foundation
import Testing

private func projectionScratch() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "framework-projection-\(UUID().uuidString)", directoryHint: .isDirectory)
}

private func writeProjectionFixture(_ data: Data, named name: String, in directory: URL) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: name)
    try data.write(to: url)
    return url
}

private enum InjectedDeletionFailure: Error {
    case refused
}

private func replaceProjectionRecordText(
    for game: GameInstall,
    replacing old: String,
    with new: String
) throws {
    let url = FrameworkModProjection.recordURL(game: game)
    let text = try String(decoding: Data(contentsOf: url), as: UTF8.self)
    let encodedOld = old.replacingOccurrences(of: "/", with: "\\/")
    let encodedNew = new.replacingOccurrences(of: "/", with: "\\/")
    let replaced = text.replacingOccurrences(of: encodedOld, with: encodedNew)
    #expect(replaced != text)
    try Data(replaced.utf8).write(to: url)
}

@Test func stageProjectsRuntimeDocumentsAndArchivesToNativeDestinations() throws {
    let root = projectionScratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let game = GameInstall(root: root.appending(path: "Game", directoryHint: .isDirectory))
    let tweakMods = game.tweakModsDirectory
    let archiveMods = game.modsEnabledDirectory
    let tweak = try writeProjectionFixture(
        Data("requires: [TweakXL]\nItems.Widget:\n  friendlyName: runtime\n".utf8),
        named: "runtime.yaml",
        in: tweakMods
    )
    let archive = try writeProjectionFixture(Data("archive".utf8), named: "resource.archive", in: archiveMods)
    _ = try writeProjectionFixture(
        Data("dependencies: [ArchiveXL]\n".utf8),
        named: "resource.archive.xl",
        in: archiveMods
    )
    let requirements = try ModFrameworkRequirements.classify(game: game)

    let projection = try FrameworkModProjection.stage(requirements: requirements, game: game)

    #expect(projection.entries.count == 3)
    #expect(projection.entries.map { $0.destination.deletingLastPathComponent().path } == [
        game.root.appending(path: "archive/Mac/mod").path,
        game.root.appending(path: "archive/Mac/mod").path,
        game.root.appending(path: "r6/tweaks").path,
    ].sorted())
    #expect(FileManager.default.fileExists(atPath: game.root.appending(path: "r6/tweaks").path))
    #expect(FileManager.default.fileExists(atPath: game.root.appending(path: "archive/Mac/mod").path))
    #expect(projection.entries.allSatisfy { FileManager.default.fileExists(atPath: $0.destination.path) })
}

@Test func stagingPersistsHashBoundProjectionRecord() throws {
    let root = projectionScratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let game = GameInstall(root: root.appending(path: "Game", directoryHint: .isDirectory))
    _ = try writeProjectionFixture(
        Data("requires: [TweakXL]\n".utf8),
        named: "runtime.tweak",
        in: game.tweakModsDirectory
    )
    let requirements = try ModFrameworkRequirements.classify(game: game)

    let projection = try FrameworkModProjection.stage(requirements: requirements, game: game)

    #expect(FileManager.default.fileExists(atPath: FrameworkModProjection.recordURL(game: game).path))
    let recorded = try #require(try FrameworkModProjection.durableRecord(game: game))
    #expect(recorded.entries == projection.entries)
    #expect(recorded.entries.allSatisfy {
        (try? Hashes.sha256Hex(ofFileAt: $0.destination)) == $0.sha256
    })
}

@Test func durableReconcileRecoversProjectionWithoutSessionRegistry() throws {
    let root = projectionScratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let game = GameInstall(root: root.appending(path: "Game", directoryHint: .isDirectory))
    _ = try writeProjectionFixture(
        Data("requires: [TweakXL]\n".utf8),
        named: "runtime.tweak",
        in: game.tweakModsDirectory
    )
    let requirements = try ModFrameworkRequirements.classify(game: game)
    let projection = try FrameworkModProjection.stage(requirements: requirements, game: game)

    _ = try FrameworkModProjection.reconcile(game: game)

    #expect(projection.entries.allSatisfy {
        !FileManager.default.fileExists(atPath: $0.destination.path)
    })
    #expect(!FileManager.default.fileExists(atPath: FrameworkModProjection.recordURL(game: game).path))
}

@Test func durableReconcileRefusesHashChangedProjectionAndKeepsRecord() throws {
    let root = projectionScratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let game = GameInstall(root: root.appending(path: "Game", directoryHint: .isDirectory))
    _ = try writeProjectionFixture(
        Data("requires: [TweakXL]\n".utf8),
        named: "runtime.tweak",
        in: game.tweakModsDirectory
    )
    let requirements = try ModFrameworkRequirements.classify(game: game)
    let projection = try FrameworkModProjection.stage(requirements: requirements, game: game)
    try Data("user replacement".utf8).write(to: projection.entries[0].destination)

    do {
        _ = try FrameworkModProjection.reconcile(game: game)
        #expect(Bool(false), "tampered projection was reconciled")
    } catch let error as FrameworkModProjectionError {
        #expect(error == .destinationHashMismatch(projection.entries[0].destination))
    }
    #expect(FileManager.default.fileExists(atPath: projection.entries[0].destination.path))
    #expect(FileManager.default.fileExists(atPath: FrameworkModProjection.recordURL(game: game).path))
}

@Test func durableReconcileRefusesTamperedRecordHashAndKeepsRecord() throws {
    let root = projectionScratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let game = GameInstall(root: root.appending(path: "Game", directoryHint: .isDirectory))
    _ = try writeProjectionFixture(
        Data("requires: [TweakXL]\n".utf8),
        named: "runtime.tweak",
        in: game.tweakModsDirectory
    )
    let requirements = try ModFrameworkRequirements.classify(game: game)
    let projection = try FrameworkModProjection.stage(requirements: requirements, game: game)
    try replaceProjectionRecordText(
        for: game,
        replacing: projection.entries[0].sha256,
        with: String(repeating: "0", count: 64)
    )

    do {
        _ = try FrameworkModProjection.reconcile(game: game)
        #expect(Bool(false), "tampered record was reconciled")
    } catch let error as FrameworkModProjectionError {
        #expect(error == .destinationHashMismatch(projection.entries[0].destination))
    }
    #expect(FileManager.default.fileExists(atPath: projection.entries[0].destination.path))
    #expect(FileManager.default.fileExists(atPath: FrameworkModProjection.recordURL(game: game).path))
}

@Test func durableReconcileRefusesTamperedRecordPathAndKeepsRecord() throws {
    let root = projectionScratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let game = GameInstall(root: root.appending(path: "Game", directoryHint: .isDirectory))
    _ = try writeProjectionFixture(
        Data("requires: [TweakXL]\n".utf8),
        named: "runtime.tweak",
        in: game.tweakModsDirectory
    )
    let requirements = try ModFrameworkRequirements.classify(game: game)
    let projection = try FrameworkModProjection.stage(requirements: requirements, game: game)
    let relativeDestination = String(
        projection.entries[0].destination.path.dropFirst(game.root.path.count + 1)
    )
    try replaceProjectionRecordText(
        for: game,
        replacing: relativeDestination,
        with: "../foreign"
    )

    do {
        _ = try FrameworkModProjection.reconcile(game: game)
        #expect(Bool(false), "unsafe record path was reconciled")
    } catch let error as FrameworkModProjectionError {
        if case .durableRecordMalformed = error {
            #expect(Bool(true))
        } else {
            #expect(Bool(false), "unexpected projection error: \(error)")
        }
    }
    #expect(FileManager.default.fileExists(atPath: projection.entries[0].destination.path))
    #expect(FileManager.default.fileExists(atPath: FrameworkModProjection.recordURL(game: game).path))
}

@Test func durableReconcileRetainsRecordWhenDeletionFails() throws {
    let root = projectionScratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let game = GameInstall(root: root.appending(path: "Game", directoryHint: .isDirectory))
    _ = try writeProjectionFixture(
        Data("requires: [TweakXL]\n".utf8),
        named: "runtime.tweak",
        in: game.tweakModsDirectory
    )
    let requirements = try ModFrameworkRequirements.classify(game: game)
    let projection = try FrameworkModProjection.stage(requirements: requirements, game: game)
    let failedDestination = projection.entries[0].destination

    do {
        _ = try FrameworkModProjection.reconcile(game: game, removeItem: { url in
            #expect(url == failedDestination)
            throw InjectedDeletionFailure.refused
        })
        #expect(Bool(false), "injected deletion failure was swallowed")
    } catch is InjectedDeletionFailure {
        #expect(FileManager.default.fileExists(atPath: failedDestination.path))
        #expect(FileManager.default.fileExists(atPath: FrameworkModProjection.recordURL(game: game).path))
    }
}

@Test func durableReconcileUsesAnAlreadyHeldInstallationLock() throws {
    let root = projectionScratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let game = GameInstall(root: root.appending(path: "Game", directoryHint: .isDirectory))
    _ = try writeProjectionFixture(
        Data("requires: [TweakXL]\n".utf8),
        named: "runtime.tweak",
        in: game.tweakModsDirectory
    )
    let lock = try InstallationLock.acquire(game: game)
    defer { lock.release() }
    let requirements = try ModFrameworkRequirements.classify(game: game)
    let projection = try FrameworkModProjection.stage(requirements: requirements, game: game)

    let removed = try FrameworkModProjection.reconcile(game: game)

    #expect(removed == projection.destinations)
    #expect(!FileManager.default.fileExists(atPath: FrameworkModProjection.recordURL(game: game).path))
}

@Test func archiveXLSidecarProjectsWithItsPayloadUsingMatchingSafeStems() throws {
    let root = projectionScratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let game = GameInstall(root: root.appending(path: "Game", directoryHint: .isDirectory))
    let archive = try writeProjectionFixture(
        Data("archive".utf8),
        named: "payload.archive",
        in: game.modsEnabledDirectory
    )
    let sidecar = try writeProjectionFixture(
        Data("dependencies: [ArchiveXL]\n".utf8),
        named: "payload.archive.xl",
        in: game.modsEnabledDirectory
    )
    let requirements = try ModFrameworkRequirements.classify(game: game)

    let projection = try FrameworkModProjection.stage(requirements: requirements, game: game)

    #expect(projection.entries.count == 2)
    #expect(projection.entries.map { $0.kind } == [
        FrameworkProjectionKind.archive,
        FrameworkProjectionKind.archive,
    ])
    let archiveStem = projection.entries
        .first { $0.source == archive.normalizedFileURL }!
        .destination.lastPathComponent
        .replacingOccurrences(of: ".archive", with: "")
    let sidecarStem = projection.entries
        .first { $0.source == sidecar.normalizedFileURL }!
        .destination.lastPathComponent
        .replacingOccurrences(of: ".archive.xl", with: "")
    #expect(archiveStem == sidecarStem)
    #expect(projection.entries.map { $0.source }.contains(archive.normalizedFileURL))
    #expect(projection.entries.map { $0.source }.contains(sidecar.normalizedFileURL))
}

@Test func enabledTreeYamlKeepsArchiveRoleAndIsNotProjectedAsTweak() throws {
    let root = projectionScratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let game = GameInstall(root: root.appending(path: "Game", directoryHint: .isDirectory))
    let enabledYaml = try writeProjectionFixture(
        Data("requires: [TweakXL]\n".utf8),
        named: "enabled.yaml",
        in: game.modsEnabledDirectory
    )

    let requirements = try ModFrameworkRequirements.classify(game: game)
    let classification = requirements.classification(for: enabledYaml)

    #expect(classification?.sourceRole == .archivePayload)
    #expect(try FrameworkModProjection.stage(requirements: requirements, game: game).entries.isEmpty)
}

@Test func externalFrameworkSourceIsRejectedByProjection() throws {
    let root = projectionScratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let game = GameInstall(root: root.appending(path: "Game", directoryHint: .isDirectory))
    let external = try writeProjectionFixture(
        Data("requires: [TweakXL]\n".utf8),
        named: "external.yaml",
        in: root.appending(path: "external")
    )
    let requirements = try ModFrameworkRequirements.classify(mods: [external])

    #expect(throws: FrameworkModProjectionError.self) {
        _ = try FrameworkModProjection.stage(requirements: requirements, game: game)
    }
}

@Test func symlinkedSourceAncestorIsRejectedByProjection() throws {
    let root = projectionScratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let game = GameInstall(root: root.appending(path: "Game", directoryHint: .isDirectory))
    let outside = try writeProjectionFixture(
        Data("requires: [TweakXL]\n".utf8),
        named: "runtime.yaml",
        in: root.appending(path: "outside")
    )
    let link = game.tweakModsDirectory.appending(path: "linked", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: game.tweakModsDirectory, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.deletingLastPathComponent())
    let linked = link.appending(path: outside.lastPathComponent)
    let requirements = try ModFrameworkRequirements.classify(sources: [
        ModFrameworkSource(url: linked, root: game.tweakModsDirectory, role: .tweakDocument)
    ])

    #expect(throws: FrameworkModProjectionError.self) {
        _ = try FrameworkModProjection.stage(requirements: requirements, game: game)
    }
}

@Test func restoreRemovesOnlyLoaderProjectionFiles() throws {
    let root = projectionScratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let game = GameInstall(root: root.appending(path: "Game", directoryHint: .isDirectory))
    let tweak = try writeProjectionFixture(
        Data("requires: [TweakXL]\n".utf8),
        named: "runtime.tweak",
        in: game.tweakModsDirectory
    )
    let unrelatedTweak = game.root.appending(path: "r6/tweaks/user.yaml")
    try FileManager.default.createDirectory(
        at: unrelatedTweak.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("user".utf8).write(to: unrelatedTweak)

    let requirements = try ModFrameworkRequirements.classify(mods: [tweak])
    _ = try FrameworkModProjection.stage(requirements: requirements, game: game)
    _ = try FrameworkModProjection.restore(game: game)

    #expect(FileManager.default.fileExists(atPath: unrelatedTweak.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: game.root.appending(path: "r6/tweaks").path)
        == ["user.yaml"])
}

@Test func restoreLeavesForeignLoaderPrefixedCollisionFiles() throws {
    let root = projectionScratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let game = GameInstall(root: root.appending(path: "Game", directoryHint: .isDirectory))
    let tweak = try writeProjectionFixture(
        Data("requires: [TweakXL]\n".utf8),
        named: "runtime.tweak",
        in: game.tweakModsDirectory
    )
    let requirements = try ModFrameworkRequirements.classify(game: game)
    let projection = try FrameworkModProjection.stage(requirements: requirements, game: game)
    let foreign = game.root.appending(path: "r6/tweaks/archive-loader-foreign.tweak")
    try Data("foreign".utf8).write(to: foreign)

    _ = try projection.restore(game: game)

    #expect(FileManager.default.fileExists(atPath: foreign.path))
    #expect(!FileManager.default.fileExists(atPath: projection.entries[0].destination.path))
}

@Test func nestedEqualNameAndContentPayloadsGetDistinctProjectionPaths() throws {
    let root = projectionScratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let game = GameInstall(root: root.appending(path: "Game", directoryHint: .isDirectory))
    let first = try writeProjectionFixture(
        Data("same".utf8),
        named: "payload.archive",
        in: game.modsEnabledDirectory.appending(path: "A")
    )
    let second = try writeProjectionFixture(
        Data("same".utf8),
        named: "payload.archive",
        in: game.modsEnabledDirectory.appending(path: "B")
    )
    _ = try writeProjectionFixture(
        Data("dependencies: [ArchiveXL]\n".utf8),
        named: "payload.archive.xl",
        in: game.modsEnabledDirectory.appending(path: "A")
    )
    _ = try writeProjectionFixture(
        Data("dependencies: [ArchiveXL]\n".utf8),
        named: "payload.archive.xl",
        in: game.modsEnabledDirectory.appending(path: "B")
    )
    let requirements = try ModFrameworkRequirements.classify(game: game)

    let projection = try FrameworkModProjection.stage(requirements: requirements, game: game)

    #expect(projection.entries.count == 4)
    #expect(Set(projection.destinations).count == 4)
    #expect(projection.entries.map { $0.source }.contains(first.normalizedFileURL))
    #expect(projection.entries.map { $0.source }.contains(second.normalizedFileURL))
}

@Test func projectionRejectsSymlinkedSourcesAndDestinations() throws {
    let root = projectionScratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let mods = root.appending(path: "mods", directoryHint: .isDirectory)
    let outside = root.appending(path: "outside.tweak")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("requires: [TweakXL]\n".utf8).write(to: outside)
    try FileManager.default.createDirectory(at: mods, withIntermediateDirectories: true)
    let symlink = mods.appending(path: "linked.tweak")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
    let game = GameInstall(root: root.appending(path: "Game", directoryHint: .isDirectory))
    let requirements = try ModFrameworkRequirements.classify(mods: [symlink])

    #expect(throws: FrameworkModProjectionError.self) {
        _ = try FrameworkModProjection.stage(requirements: requirements, game: game)
    }
}

@Test func fingerprintUsesOfflineDocumentsAndProjectionInputsSeparately() throws {
    let root = projectionScratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let game = GameInstall(root: root.appending(path: "Game", directoryHint: .isDirectory))
    let offline = try writeProjectionFixture(
        Data("Items.Widget:\n  friendlyName: offline\n".utf8),
        named: "offline.yaml",
        in: root.appending(path: "mods")
    )
    let runtime = try writeProjectionFixture(
        Data("requires: [TweakXL]\n".utf8),
        named: "runtime.yaml",
        in: root.appending(path: "mods")
    )
    let requirements = try ModFrameworkRequirements.classify(mods: [offline, runtime])
    let manifest = BaselineManifest(
        id: "generation",
        capturedAt: "now",
        gameVersion: "2.5.0",
        storefront: "gog",
        loaderVersion: LoaderVersion.current,
        archives: [],
        tweaks: []
    )

    let base = try TweakFingerprint.compute(
        game: game,
        manifest: manifest,
        mods: [offline, runtime],
        inventory: ArchiveXLInventory(matches: [
            ArchiveXLMatch(path: "/installed/ArchiveXL.dylib", reason: "must be ignored")
        ]),
        requirements: requirements,
        runtimeProjectionInputs: ["r6/tweaks/runtime.yaml:one"]
    )
    try Data("requires: [TweakXL]\nchanged: true\n".utf8).write(to: runtime)
    let changedRuntimeSource = try TweakFingerprint.compute(
        game: game,
        manifest: manifest,
        mods: [offline, runtime],
        inventory: ArchiveXLInventory(matches: [
            ArchiveXLMatch(path: "/installed/ArchiveXL.dylib", reason: "must be ignored")
        ]),
        requirements: requirements,
        runtimeProjectionInputs: ["r6/tweaks/runtime.yaml:one"]
    )
    let changedProjection = try TweakFingerprint.compute(
        game: game,
        manifest: manifest,
        mods: [offline, runtime],
        inventory: ArchiveXLInventory(matches: [
            ArchiveXLMatch(path: "/installed/ArchiveXL.dylib", reason: "must be ignored")
        ]),
        requirements: requirements,
        runtimeProjectionInputs: ["r6/tweaks/runtime.yaml:two"]
    )

    #expect(base.value == changedRuntimeSource.value)
    #expect(base.value != changedProjection.value)
    #expect(base.canonicalInput.contains("offline.yaml"))
    #expect(!base.canonicalInput.contains("runtime.yaml "))
    #expect(!base.canonicalInput.contains("installed/ArchiveXL.dylib"))
}

