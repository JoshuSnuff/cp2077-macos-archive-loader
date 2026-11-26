import CP2077ArchiveCore
import Foundation
import Testing

private func tweakPlanScratch() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "tweak-plan-\(UUID().uuidString)", directoryHint: .isDirectory)
}
private func writeTweakPlanBlob(
    _ builder: TweakBlobBuilder,
    named name: String,
    in directory: URL
) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: name)
    try builder.build().write(to: url)
    return url
}

@Test func plannerSortsModsAndAppliesDefaultOperationsToEveryOwner() throws {
    let root = tweakPlanScratch()
    defer { try? FileManager.default.removeItem(at: root) }

    let base = try writeTweakPlanBlob(makeSampleBlob(), named: "tweakdb.bin", in: root)
    let ep1 = try writeTweakPlanBlob(makeSampleBlob(), named: "tweakdb_ep1.bin", in: root)
    let first = root.appending(path: "a_first.yaml")
    let second = root.appending(path: "z_second.yaml")
    try Data("Items.Widget:\n  friendlyName: first\n".utf8).write(to: first)
    try Data("Items.Widget:\n  friendlyName: second\n".utf8).write(to: second)

    let plan = try TweakPlanner.plan(mods: [second, first], blobs: [ep1, base])

    #expect(plan.targets == [base.normalizedFileURL, ep1.normalizedFileURL])
    #expect(plan.operationCount == 2)
    #expect(plan.losers.count == 1)
    #expect(plan.losers[0].mod.lastPathComponent == "z_second.yaml")
    #expect(plan.losers[0].winner.lastPathComponent == "a_first.yaml")
    #expect(plan.workByBlob[base.normalizedFileURL]?.count == 1)
    #expect(plan.workByBlob[ep1.normalizedFileURL]?.count == 1)
}

@Test func selectorNarrowsWorkToTheNamedBlob() throws {
    let root = tweakPlanScratch()
    defer { try? FileManager.default.removeItem(at: root) }

    let base = try writeTweakPlanBlob(makeSampleBlob(), named: "tweakdb.bin", in: root)
    let ep1 = try writeTweakPlanBlob(makeSampleBlob(), named: "tweakdb_ep1.bin", in: root)
    let mod = root.appending(path: "ep1.yaml")
    try Data("Items.Widget:\n  friendlyName:\n    ep1: selected\n".utf8).write(to: mod)

    let plan = try TweakPlanner.plan(mods: [mod], blobs: [base, ep1])

    #expect(plan.operationCount == 1)
    #expect(plan.workByBlob[base.normalizedFileURL] == nil)
    #expect(plan.workByBlob[ep1.normalizedFileURL]?.count == 1)
}

@Test func defaultTargetingUsesOnlyPresentOwningBlobs() throws {
    let root = tweakPlanScratch()
    defer { try? FileManager.default.removeItem(at: root) }

    let base = try writeTweakPlanBlob(makeSampleBlob(), named: "tweakdb.bin", in: root)
    let mod = root.appending(path: "base-only.yaml")
    try Data("Items.Widget:\n  friendlyName: base_only\n".utf8).write(to: mod)

    let plan = try TweakPlanner.plan(mods: [mod], blobs: [base])

    #expect(plan.targets == [base.normalizedFileURL])
    #expect(plan.operationCount == 1)
}

@Test func selectingAnAbsentBlobIsFatal() throws {
    let root = tweakPlanScratch()
    defer { try? FileManager.default.removeItem(at: root) }

    let base = try writeTweakPlanBlob(makeSampleBlob(), named: "tweakdb.bin", in: root)
    let mod = root.appending(path: "ep1.yaml")
    try Data("Items.Widget:\n  friendlyName:\n    ep1: selected\n".utf8).write(to: mod)

    #expect(throws: TweakPlanError.self) {
        _ = try TweakPlanner.plan(mods: [mod], blobs: [base])
    }
}
@Test func operationTargetingNoBlobIsAFatalNamedPlanError() throws {
    let root = tweakPlanScratch()
    defer { try? FileManager.default.removeItem(at: root) }

    let base = try writeTweakPlanBlob(makeSampleBlob(), named: "tweakdb.bin", in: root)
    let mod = root.appending(path: "missing.yaml")
    try Data("Items.Missing:\n  friendlyName: absent\n".utf8).write(to: mod)

    #expect(throws: TweakPlanError.self) {
        _ = try TweakPlanner.plan(mods: [mod], blobs: [base])
    }
}

@Test func unsupportedOperationForExistingTargetIsAFatalNamedPlanError() throws {
    let root = tweakPlanScratch()
    defer { try? FileManager.default.removeItem(at: root) }

    let base = try writeTweakPlanBlob(makeSampleBlob(), named: "tweakdb.bin", in: root)
    let mod = root.appending(path: "unsupported.yaml")
    try Data("Items.Widget:\n  friendlyName: !append\n    - extra\n".utf8).write(to: mod)

    #expect(throws: TweakPlanError.self) {
        _ = try TweakPlanner.plan(mods: [mod], blobs: [base])
    }
}
