import CP2077ArchiveCore
import Foundation
import Testing

private func frameworkRequirementsScratch() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "framework-requirements-\(UUID().uuidString)", directoryHint: .isDirectory)
}

private func writeFrameworkFixture(_ text: String, named name: String, in directory: URL) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: name)
    try Data(text.utf8).write(to: url)
    return url
}

@Test func classifierReadsOnlyExactRootFrameworkDependencies() throws {
    let root = frameworkRequirementsScratch()
    defer { try? FileManager.default.removeItem(at: root) }

    let offline = try writeFrameworkFixture(
        "record:\n  dependencies: [ArchiveXL]\n",
        named: "offline.yaml",
        in: root
    )
    let tweak = try writeFrameworkFixture(
        "requires: [TweakXL, TweakXLExtra]\n",
        named: "runtime.tweak",
        in: root
    )
    let archive = try writeFrameworkFixture("opaque", named: "resource.archive", in: root)
    let sidecar = try writeFrameworkFixture(
        "dependencies: [ArchiveXL]\n",
        named: "resource.archive.yaml",
        in: root
    )

    let requirements = try ModFrameworkRequirements.classify(mods: [offline, tweak, archive])

    #expect(requirements.archiveXLMods == [archive.normalizedFileURL])
    #expect(requirements.tweakXLMods == [tweak.normalizedFileURL])
    #expect(requirements.offlineMods == [offline.normalizedFileURL])
    #expect(requirements.unknownMods.isEmpty)
    #expect(requirements.classification(for: archive)?.metadata == sidecar.normalizedFileURL)
    #expect(requirements.classification(for: offline)?.requirements.isEmpty == true)
}

@Test func malformedYamlIsAClassificationErrorForTheSourceMod() throws {
    let root = frameworkRequirementsScratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let malformed = try writeFrameworkFixture(
        "requires: [ArchiveXL\n",
        named: "broken.yaml",
        in: root
    )

    #expect(throws: ModFrameworkClassificationError.self) {
        _ = try ModFrameworkRequirements.classify(mods: [malformed])
    }
}

@Test func opaqueArchivesWithoutSidecarsRemainUnknown() throws {
    let root = frameworkRequirementsScratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try writeFrameworkFixture("opaque", named: "unknown.archive", in: root)

    let requirements = try ModFrameworkRequirements.classify(mods: [archive])

    #expect(requirements.unknownMods == [archive.normalizedFileURL])
    #expect(requirements.archiveXLMods.isEmpty)
    #expect(requirements.tweakXLMods.isEmpty)
}

@Test func archiveXLSidecarIsAssociatedWithItsArchivePayload() throws {
    let root = frameworkRequirementsScratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try writeFrameworkFixture("opaque", named: "payload.archive", in: root)
    let sidecar = try writeFrameworkFixture(
        "dependencies: [ArchiveXL]\n",
        named: "payload.archive.xl",
        in: root
    )

    let requirements = try ModFrameworkRequirements.classify(mods: [archive, sidecar])

    #expect(requirements.classifications.count == 1)
    #expect(requirements.archiveXLMods == [archive.normalizedFileURL])
    #expect(requirements.classification(for: archive)?.associatedFiles == [sidecar.normalizedFileURL])
}

@Test func malformedArchiveXLSidecarIsAClassificationError() throws {
    let root = frameworkRequirementsScratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try writeFrameworkFixture("opaque", named: "payload.archive", in: root)
    _ = try writeFrameworkFixture(
        "dependencies: [ArchiveXL\n",
        named: "payload.archive.xl",
        in: root
    )

    #expect(throws: ModFrameworkClassificationError.self) {
        _ = try ModFrameworkRequirements.classify(mods: [archive])
    }
}

@Test func classifierOrdersInputsByCompleteUtf8Path() throws {
    let root = frameworkRequirementsScratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let z = try writeFrameworkFixture("requires: [ArchiveXL]\n", named: "z.yaml", in: root)
    let a = try writeFrameworkFixture("requires: [ArchiveXL]\n", named: "a.yaml", in: root)

    let requirements = try ModFrameworkRequirements.classify(mods: [z, a])

    #expect(requirements.archiveXLMods.map(\.lastPathComponent) == ["a.yaml", "z.yaml"])
    #expect(requirements.classifications.map(\.mod.lastPathComponent) == ["a.yaml", "z.yaml"])
}

