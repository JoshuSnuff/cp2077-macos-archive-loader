import CP2077ArchiveCore
import Foundation
import Testing

private func modsDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "archive-loader-mods-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func touch(_ directory: URL, _ name: String) throws {
    let url = directory.appending(path: name)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("mod".utf8).write(to: url)
}

@Test func modsAreOrderedByBytesNotByLocale() throws {
    let directory = try modsDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    // '#' is 0x23, '0' is 0x30, 'x' is 0x78. A UTF-8 collation would weight
    // the punctuation loosely and reorder these, changing which mod wins a
    // contested hash with no error anywhere.
    try touch(directory, "x_last.archive")
    try touch(directory, "0_middle.archive")
    try touch(directory, "###_first.archive")

    let mods = try ModCollection.enabledMods(in: directory)

    #expect(mods.map(\.lastPathComponent)
        == ["###_first.archive", "0_middle.archive", "x_last.archive"])
}

@Test func modsInSubdirectoriesAreFound() throws {
    let directory = try modsDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try touch(directory, "top.archive")
    try touch(directory, "nested/deeper/inner.archive")

    let mods = try ModCollection.enabledMods(in: directory)

    // Byte order over the full path: 'n' (0x6e) sorts before 't' (0x74).
    #expect(mods.map(\.lastPathComponent) == ["inner.archive", "top.archive"])
}

@Test func onlyArchiveFilesAreCollected() throws {
    let directory = try modsDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try touch(directory, "real.archive")
    try touch(directory, "readme.txt")
    try touch(directory, "notes.md")

    let mods = try ModCollection.enabledMods(in: directory)

    #expect(mods.map(\.lastPathComponent) == ["real.archive"])
}

@Test func namesWithSpacesSurvive() throws {
    let directory = try modsDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try touch(directory, "Some Mod With Spaces.archive")

    let mods = try ModCollection.enabledMods(in: directory)

    #expect(mods.map(\.lastPathComponent) == ["Some Mod With Spaces.archive"])
}

@Test func aMissingOrEmptyDirectoryYieldsNoMods() throws {
    let directory = try modsDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(try ModCollection.enabledMods(in: directory).isEmpty)
    #expect(try ModCollection.enabledMods(in: directory.appending(path: "absent")).isEmpty)
}

@Test func collectingReadsTheInstallsEnabledDirectory() throws {
    let game = try TestGame()
    defer { game.cleanUp() }
    try FileManager.default.createDirectory(
        at: game.install.modsEnabledDirectory,
        withIntermediateDirectories: true
    )
    try Data("mod".utf8).write(
        to: game.install.modsEnabledDirectory.appending(path: "a.archive")
    )

    #expect(try ModCollection.enabledMods(game: game.install).map(\.lastPathComponent)
        == ["a.archive"])
}
