import CP2077ArchiveCore
import Foundation
import Testing

private func makeWorkDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "archive-loader-clone-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func cloneCopiesFileContents() throws {
    let work = try makeWorkDirectory()
    defer { try? FileManager.default.removeItem(at: work) }
    let source = work.appending(path: "source.archive")
    let destination = work.appending(path: "destination.archive")
    try Data("vanilla bytes".utf8).write(to: source)

    try Clone.file(from: source, to: destination)

    #expect(try Data(contentsOf: destination) == Data("vanilla bytes".utf8))
}

@Test func cloneRefusesAnExistingDestination() throws {
    let work = try makeWorkDirectory()
    defer { try? FileManager.default.removeItem(at: work) }
    let source = work.appending(path: "source.archive")
    let destination = work.appending(path: "destination.archive")
    try Data("new".utf8).write(to: source)
    try Data("old".utf8).write(to: destination)

    #expect(throws: CloneError.self) {
        try Clone.file(from: source, to: destination)
    }
    // The refusal must not have damaged what was already there.
    #expect(try Data(contentsOf: destination) == Data("old".utf8))
}

@Test func replaceFileOverwritesAtomicallyAndLeavesNoTemporary() throws {
    let work = try makeWorkDirectory()
    defer { try? FileManager.default.removeItem(at: work) }
    let source = work.appending(path: "source.archive")
    let destination = work.appending(path: "destination.archive")
    try Data("restored".utf8).write(to: source)
    try Data("patched".utf8).write(to: destination)

    try Clone.replaceFile(from: source, to: destination)

    #expect(try Data(contentsOf: destination) == Data("restored".utf8))
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: work.path)
        .filter { $0.hasPrefix(".archive-loader-") }
    #expect(leftovers.isEmpty)
}

@Test func replaceFileLeavesTheTargetUntouchedWhenTheSourceIsMissing() throws {
    let work = try makeWorkDirectory()
    defer { try? FileManager.default.removeItem(at: work) }
    let destination = work.appending(path: "destination.archive")
    try Data("patched".utf8).write(to: destination)

    #expect(throws: CloneError.self) {
        try Clone.replaceFile(from: work.appending(path: "absent.archive"), to: destination)
    }

    #expect(try Data(contentsOf: destination) == Data("patched".utf8))
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: work.path)
        .filter { $0.hasPrefix(".archive-loader-") }
    #expect(leftovers.isEmpty)
}

@Test func verifySupportSucceedsOnACloneCapableVolume() throws {
    let work = try makeWorkDirectory()
    defer { try? FileManager.default.removeItem(at: work) }

    try Clone.verifySupport(in: work.appending(path: "loader", directoryHint: .isDirectory))

    // The probe must not leave anything behind.
    let contents = try FileManager.default.contentsOfDirectory(
        atPath: work.appending(path: "loader", directoryHint: .isDirectory).path
    )
    #expect(contents.isEmpty)
}
