import CP2077ArchiveCore
import Foundation

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case missingValue(String)

    var description: String {
        switch self {
        case let .usage(message): return message
        case let .missingValue(flag): return "missing value for \(flag)"
        }
    }
}

@main
struct CP2077PatcherCLI {
    static func main() {
        do {
            try run()
        } catch {
            fputs("error: \(error)\n", stderr)
            exit(1)
        }
    }

    static func run() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            printUsage()
            return
        }
        args.removeFirst()

        switch command {
        case "detect":
            try detect(args)
        case "scan":
            try scan(args)
        case "verify":
            try verify(args)
        case "patch":
            try patch(args)
        case "patch-hashes":
            try patchHashes(args)
        case "restore":
            try restore(args)
        case "help", "--help", "-h":
            printUsage()
        default:
            throw CLIError.usage("unknown command: \(command)")
        }
    }

    static func scan(_ args: [String]) throws {
        guard !args.isEmpty else { throw CLIError.usage("usage: cp2077-patcher scan MOD.archive [...]") }
        for arg in args {
            let url = URL(fileURLWithPath: arg)
            let scan = try ModScanner.scan(url: url)
            let archive = scan.archive
            print("\n\(url.path)")
            print("  records=\(archive.fileEntryCount) segments=\(archive.fileSegmentCount) deps=\(archive.dependencyCount)")
            print("  crcMatch=\(archive.storedCRC == archive.computedCRC)")
            print("  archiveOnlyCandidate=\(scan.likelyArchiveOnly)")
            for note in scan.notes {
                print("  note: \(note)")
            }
        }
    }

    static func detect(_ args: [String]) throws {
        if let detected = GameInstall.detectInstalledGame() {
            print(detected.path)
        } else {
            throw CLIError.usage("could not detect Cyberpunk 2077. Pass --game explicitly.")
        }
    }

    static func verify(_ args: [String]) throws {
        let options = try Options(args)
        guard let gamePath = options.value("--game") else {
            throw CLIError.usage("usage: cp2077-patcher verify --game GAME_DIR [--mods MOD.archive [...]]")
        }
        let game = GameInstall(root: URL(fileURLWithPath: gamePath))

        // Without --mods only the structural checks can run: there is no plan to
        // compare against, so a patched record cannot be told from a stock one.
        let modPaths = options.values(after: "--mods")
        let plan = modPaths.isEmpty
            ? PatchPlan(winners: [:], officialWork: [:], newResources: [], losers: [])
            : try PatchPlanner.plan(mods: modPaths.map { URL(fileURLWithPath: $0) }, game: game)
        if modPaths.isEmpty {
            print("note: no --mods given, checking archive structure only")
        }

        let report = try PlanVerifier.verify(plan: plan, game: game)
        for archive in report.archives {
            let counts = archive.records.isEmpty
                ? ""
                : " planned=\(archive.records.count)"
            print("\(archive.isClean ? "OK  " : "BAD ") \(archive.archive.lastPathComponent)\(counts)")
            for issue in archive.issues {
                print("       ! \(issue)")
            }
            for record in archive.records where record.verdict != .matchesPlan {
                print("       \(record.verdict == .unpatchedStockRecord ? "stock" : "differs") \(Hashes.hex64(record.hash))")
                for issue in record.issues {
                    print("         - \(issue)")
                }
            }
        }

        print(
            "summary: \(report.matchingRecordCount) match plan,"
                + " \(report.differingRecordCount) differ,"
                + " \(report.unpatchedRecordCount) unpatched stock"
                + " across \(report.archives.count) archives"
        )
        if !report.isClean {
            throw CLIError.usage("verification failed")
        }
    }

    static func patch(_ args: [String]) throws {
        let options = try Options(args)
        guard let gamePath = options.value("--game") else {
            throw CLIError.usage("usage: cp2077-patcher patch --game GAME_DIR [--strategy hybrid|aggressive] [--target TARGET.archive] --mods MOD.archive [...]")
        }
        let modPaths = options.values(after: "--mods")
        guard !modPaths.isEmpty else {
            throw CLIError.usage("usage: cp2077-patcher patch --game GAME_DIR [--strategy hybrid|aggressive] [--target TARGET.archive] --mods MOD.archive [...]")
        }

        let game = GameInstall(root: URL(fileURLWithPath: gamePath))
        let patcher = RDARPatcher(game: game)
        let explicitTarget = options.value("--target").map { URL(fileURLWithPath: $0) }
        let strategy = options.value("--strategy") ?? "hybrid"
        let modURLs = modPaths.map { URL(fileURLWithPath: $0) }

        switch strategy {
        case "hybrid":
            if explicitTarget != nil {
                print("warning: --target is ignored by --strategy hybrid")
            }

            // One plan across every mod. Conflicts have to be resolved before
            // anything is written, because the write itself is last-wins.
            let plan = try PatchPlanner.plan(mods: modURLs, game: game)
            print("plan: \(plan.overrideCount) override records, \(plan.newResources.count) new resources")
            print("      \(plan.targets.count) official archives to rewrite, \(plan.losers.count) conflicts")
            for loser in plan.losers {
                print(
                    "  conflict: \(Hashes.hex64(loser.hash)) in \(loser.modArchive.lastPathComponent)"
                        + " loses to \(loser.winnerArchive.lastPathComponent)"
                )
            }

            let summary = try patcher.apply(plan: plan)
            for archive in summary.archives {
                print("  patched \(archive.targetArchive.lastPathComponent)")
                print(
                    "    records=\(archive.patchedCount) replaced=\(archive.replacedCount)"
                        + " inserted=\(archive.insertedCount)"
                )
                print("    backup=\(archive.backupDirectory.path)")
            }
            if let loose = summary.looseArchive {
                print("  looseArchive=\(loose.path)")
            }
            print("patched \(summary.overrideRecordCount) records across \(summary.archives.count) archives")
        case "aggressive":
            for modURL in modURLs {
                let target = try patcher.chooseTarget(sourceArchive: modURL, explicitTarget: explicitTarget)
                let summary = try patcher.patchAll(sourceArchive: modURL, targetArchive: target)
                print("aggressively patched \(modURL.lastPathComponent) -> \(target.lastPathComponent)")
                print("  records=\(summary.patchedCount) inserted=\(summary.insertedCount) replaced=\(summary.replacedCount)")
                print("  backup=\(summary.backupDirectory.path)")
            }
        default:
            throw CLIError.usage("unknown strategy: \(strategy)")
        }
    }

    static func patchHashes(_ args: [String]) throws {
        let options = try Options(args)

        guard let gamePath = options.value("--game"),
              let sourcePath = options.value("--source"),
              let targetPath = options.value("--target")
        else {
            throw CLIError.usage(
                "usage: cp2077-patcher patch-hashes --game GAME_DIR --source MOD.archive --target TARGET.archive --hashes HEX [...]"
            )
        }

        let hashStrings = options.values(after: "--hashes")
        guard !hashStrings.isEmpty else {
            throw CLIError.usage("patch-hashes requires at least one hash")
        }

        let hashes = try hashStrings.map { value -> UInt64 in
            let normalized = value.lowercased().hasPrefix("0x") ? String(value.dropFirst(2)) : value
            guard let hash = UInt64(normalized, radix: 16) else {
                throw CLIError.usage("invalid hash: " + value)
            }
            return hash
        }

        let game = GameInstall(root: URL(fileURLWithPath: gamePath))
        let patcher = RDARPatcher(game: game)
        let summary = try patcher.patchHashes(
            sourceArchive: URL(fileURLWithPath: sourcePath),
            targetArchive: URL(fileURLWithPath: targetPath),
            hashes: hashes
        )

        print("selectively patched " + sourcePath)
        print("target=" + summary.targetArchive.path)
        print(
            "records=" + String(summary.patchedCount)
                + " inserted=" + String(summary.insertedCount)
                + " replaced=" + String(summary.replacedCount)
        )
        print("backup=" + summary.backupDirectory.path)
    }

    static func restore(_ args: [String]) throws {
        let options = try Options(args)
        guard let gamePath = options.value("--game") else {
            throw CLIError.usage("usage: cp2077-patcher restore --game GAME_DIR [--backup BACKUP_DIR | --latest]")
        }
        let store = BackupStore(game: GameInstall(root: URL(fileURLWithPath: gamePath)))
        let restored: URL
        if let backupPath = options.value("--backup") {
            restored = try store.restore(backupDirectory: URL(fileURLWithPath: backupPath))
        } else {
            restored = try store.restoreLatest()
        }
        print("restored \(restored.path)")
    }

    static func printUsage() {
        print("""
        cp2077-patcher

        Commands:
          scan MOD.archive [...]
          detect
          verify --game GAME_DIR [--mods MOD.archive [...]]
          patch --game GAME_DIR [--strategy hybrid|aggressive] [--target TARGET.archive] --mods MOD.archive [...]
          restore --game GAME_DIR [--backup BACKUP_DIR | --latest]

        Scope:
          Native macOS Cyberpunk 2077, archive-only PC .archive mods.
        """)
    }
}

struct Options {
    let args: [String]

    init(_ args: [String]) throws {
        self.args = args
    }

    func value(_ flag: String) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        let value = args[index + 1]
        return value.hasPrefix("--") ? nil : value
    }

    func values(after flag: String) -> [String] {
        guard let index = args.firstIndex(of: flag) else { return [] }
        var values: [String] = []
        for arg in args[(index + 1)...] {
            if arg.hasPrefix("--") { break }
            values.append(arg)
        }
        return values
    }
}
