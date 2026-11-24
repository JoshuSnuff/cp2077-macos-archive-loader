import CP2077ArchiveCore
import Foundation
import Testing

@Test func discoveryRecursesAndAcceptsTheThreeSupportedExtensions() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "tweak-discovery-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appending(path: "AuthorA/ModOne"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appending(path: "AuthorB"), withIntermediateDirectories: true)
    try Data().write(to: root.appending(path: "AuthorA/ModOne/balance.yaml"))
    try Data().write(to: root.appending(path: "AuthorA/ModOne/economy.yml"))
    try Data().write(to: root.appending(path: "AuthorB/loot.tweak"))
    try Data().write(to: root.appending(path: "AuthorB/readme.md"))

    let mods = try TweakModCollection.mods(in: root)

    #expect(mods.count == 3)
    #expect(mods.allSatisfy { ["yaml", "yml", "tweak"].contains($0.pathExtension) })
}

@Test func discoveryOrdersByUTF8BytesAcrossTheFullPath() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "tweak-order-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for name in ["zz.yaml", "0_first.yaml", "###-early.yaml", "Middle.yaml"] {
        try Data().write(to: root.appending(path: name))
    }

    #expect(try TweakModCollection.mods(in: root).map(\.lastPathComponent)
        == ["###-early.yaml", "0_first.yaml", "Middle.yaml", "zz.yaml"])
}

@Test func missingDirectoryYieldsNoMods() throws {
    let absent = FileManager.default.temporaryDirectory
        .appending(path: "missing-tweaks-\(UUID().uuidString)")

    #expect(try TweakModCollection.mods(in: absent).isEmpty)
}
