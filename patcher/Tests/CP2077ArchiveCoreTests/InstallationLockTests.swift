import CP2077ArchiveCore
import Foundation
import Testing

@Test func aSecondAcquisitionIsRefusedWhileTheFirstIsHeld() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let first = try InstallationLock.acquire(game: game.install)
    defer { first.release() }

    // flock associates the lock with the open file description, so a second
    // open() in this same process conflicts exactly as another process would.
    #expect(throws: InstallationLockError.self) {
        _ = try InstallationLock.acquire(game: game.install)
    }
}

@Test func releasingLetsTheNextCallerIn() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let first = try InstallationLock.acquire(game: game.install)
    first.release()

    let second = try InstallationLock.acquire(game: game.install)
    second.release()
}

@Test func releaseIsIdempotent() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let lock = try InstallationLock.acquire(game: game.install)
    lock.release()
    lock.release()

    let again = try InstallationLock.acquire(game: game.install)
    again.release()
}

@Test func aDeadHolderDoesNotWedgeTheInstall() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    // Stand in for a SIGKILLed session: a holder that goes away without ever
    // calling release. The kernel must drop the lock with the descriptor.
    do {
        let abandoned = try InstallationLock.acquire(game: game.install)
        _ = abandoned
    }

    let recovered = try InstallationLock.acquire(game: game.install)
    recovered.release()
}

@Test func theLockFileLivesUnderState() throws {
    let game = try TestGame()
    defer { game.cleanUp() }

    let lock = try InstallationLock.acquire(game: game.install)
    defer { lock.release() }

    #expect(lock.lockFile.path == game.install.stateDirectory.appending(path: "lock").path)
    #expect(FileManager.default.fileExists(atPath: lock.lockFile.path))
}
