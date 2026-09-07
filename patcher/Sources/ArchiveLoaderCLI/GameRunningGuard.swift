import CP2077ArchiveCore

/// One refusal, shared by every command that reads or writes the official
/// archives.
///
/// A live session reads whatever is on disk next, so rewriting an archive
/// underneath it corrupts the running game, and restoring one hands it vanilla
/// data it never opened. Callers check twice: once before the installation
/// lock, so a live session gets this message rather than a lock-contention
/// one, and once after, because the game can start while the lock is being
/// acquired.
enum GameRunningGuard {
    /// - Parameters:
    ///   - alreadyRunning: whether the game predates this invocation, which is
    ///     the distinction `run` draws between a session it did not start and
    ///     one it would have.
    ///   - consequence: what proceeding would do, completing the sentence
    ///     "Quit it first: ...".
    static func refuseIfRunning(
        game: GameInstall,
        alreadyRunning: Bool = false,
        consequence: String
    ) throws {
        guard GameProcess.isRunning(game: game) else { return }
        throw CLIError.usage(
            "Cyberpunk 2077 is \(alreadyRunning ? "already " : "")running from this installation."
                + " Quit it first: \(consequence)."
        )
    }
}
