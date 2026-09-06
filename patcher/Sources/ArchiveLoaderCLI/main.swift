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
struct ArchiveLoaderCLI {
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
        case "prune":
            try prune(args)
        case "help", "--help", "-h":
            printUsage()
        default:
            throw CLIError.usage("unknown command: \(command)")
        }
    }

    static func scan(_ args: [String]) throws {
        guard !args.isEmpty else { throw CLIError.usage("usage: archive-loader scan MOD.archive [...]") }
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
        var showAll = false
        var format = "text"
        var explicitPath: String?
        var index = 0

        while index < args.count {
            switch args[index] {
            case "--all":
                showAll = true
                index += 1
            case "--format":
                guard index + 1 < args.count else { throw CLIError.missingValue("--format") }
                format = args[index + 1]
                index += 2
            case "--game":
                guard index + 1 < args.count else { throw CLIError.missingValue("--game") }
                explicitPath = args[index + 1]
                index += 2
            default:
                throw CLIError.usage("unknown detect option: \(args[index])")
            }
        }

        guard format == "text" || format == "json" else {
            throw CLIError.usage("unknown detect format: \(format) (expected text or json)")
        }
        if showAll && explicitPath != nil {
            throw CLIError.usage("detect --all cannot be combined with --game")
        }

        let candidates: [GameCandidate]
        if showAll {
            candidates = GameDiscovery.discover()
        } else {
            let explicitRoot = explicitPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            candidates = try GameDiscovery.resolve(explicitRoot: explicitRoot)
        }

        guard !candidates.isEmpty else {
            throw CLIError.usage("could not detect Cyberpunk 2077. Pass --game explicitly.")
        }

        if !showAll && candidates.count > 1 {
            let paths = candidates.map { "  \($0.root.path)" }.joined(separator: "\n")
            throw CLIError.usage(
                "multiple Cyberpunk 2077 installations found; pass --game explicitly:\n\(paths)"
            )
        }

        let selected = showAll ? candidates : [candidates[0]]
        if format == "json" {
            let output = selected.map(DetectedGame.init)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(output)
            print(String(decoding: data, as: UTF8.self))
        } else {
            for candidate in selected {
                print(candidate.root.path)
            }
        }
    }

    static func verify(_ args: [String]) throws {
        let options = try Options(args)
        guard let gamePath = options.value("--game") else {
            throw CLIError.usage("usage: archive-loader verify --game GAME_DIR [--mods MOD.archive [...]]")
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
            throw CLIError.usage("usage: archive-loader patch --game GAME_DIR [--keep N] [--strategy hybrid|aggressive] [--target TARGET.archive] --mods MOD.archive [...]")
        }
        let modPaths = options.values(after: "--mods")
        guard !modPaths.isEmpty else {
            throw CLIError.usage("usage: archive-loader patch --game GAME_DIR [--keep N] [--strategy hybrid|aggressive] [--target TARGET.archive] --mods MOD.archive [...]")
        }

        let game = GameInstall(root: URL(fileURLWithPath: gamePath))
        let patcher = RDARPatcher(game: game)
        let explicitTarget = options.value("--target").map { URL(fileURLWithPath: $0) }
        let strategy = options.value("--strategy") ?? "hybrid"
        let modURLs = modPaths.map { URL(fileURLWithPath: $0) }
        let keep = try retentionCount(options.value("--keep"))

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

            let summary = try patcher.apply(plan: plan, keepBackups: keep)
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
                let summary = try patcher.patchAll(
                    sourceArchive: modURL,
                    targetArchive: target,
                    keepBackups: keep
                )
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
                "usage: archive-loader patch-hashes --game GAME_DIR --source MOD.archive --target TARGET.archive --hashes HEX [...]"
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
            throw CLIError.usage("usage: archive-loader restore --game GAME_DIR [--backup BACKUP_DIR | --latest]")
        }
        let store = BackupStore(game: GameInstall(root: URL(fileURLWithPath: gamePath)))
        if let backupPath = options.value("--backup") {
            _ = try store.restore(backupDirectory: URL(fileURLWithPath: backupPath)) {
                print("restored \($0.path)")
            }
        } else {
            _ = try store.restoreLatest {
                print("restored \($0.path)")
            }
        }
    }

    static func prune(_ args: [String]) throws {
        let options = try Options(args)
        guard let gamePath = options.value("--game") else {
            throw CLIError.usage("usage: archive-loader prune --game GAME_DIR [--keep N] [--dry-run]")
        }
        let dryRun = args.contains("--dry-run")
        let keep = try retentionCount(options.value("--keep"))
        let store = BackupStore(game: GameInstall(root: URL(fileURLWithPath: gamePath)))
        let removed = try store.prune(keep: keep, dryRun: dryRun)
        for directory in removed {
            print("\(dryRun ? "would prune" : "pruned") \(directory.path)")
        }
        if removed.isEmpty {
            print("nothing to prune")
        }
    }

    static func retentionCount(_ value: String?) throws -> Int {
        guard let value else { return 3 }
        guard let count = Int(value), count >= 0 else {
            throw CLIError.usage("--keep requires a non-negative integer")
        }
        return count
    }

    static func printUsage() {
        print("""
        archive-loader

        Commands:
          scan MOD.archive [...]
          detect [--all] [--format text|json] [--game GAME_DIR]
          verify --game GAME_DIR [--mods MOD.archive [...]]
          patch --game GAME_DIR [--keep N] [--strategy hybrid|aggressive] [--target TARGET.archive] --mods MOD.archive [...]
          restore --game GAME_DIR [--backup RUN_OR_ARCHIVE_DIR | --latest]
          prune --game GAME_DIR [--keep N] [--dry-run]

        Scope:
          Native macOS Cyberpunk 2077, archive-only PC .archive mods.
        """)
    }
}

private struct DetectedGame: Encodable {
    let path: String
    let version: String
    let sources: [String]

    init(_ candidate: GameCandidate) {
        path = candidate.root.path
        version = candidate.version
        sources = candidate.sources
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
