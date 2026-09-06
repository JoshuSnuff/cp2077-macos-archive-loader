import CP2077ArchiveCore

enum Rebaseline {
    static func run(
        game: GameInstall,
        store: BaselineStore,
        candidate: GameCandidate,
        assumeClean: Bool
    ) throws {
        throw CLIError.usage("--rebaseline is not implemented yet")
    }
}
