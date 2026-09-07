import CP2077ArchiveCore
import Foundation

enum StatusCommand {
    static func run(_ args: [String]) throws {
        let options = try Options(args)
        let deep = args.contains("--deep")

        let candidates = try GameDiscovery.resolve(
            explicitRoot: options.value("--game").map { URL(fileURLWithPath: $0, isDirectory: true) }
        )
        guard let candidate = candidates.first, candidates.count == 1 else {
            throw CLIError.usage("could not resolve a single game installation; pass --game")
        }
        let game = GameInstall(root: candidate.root)
        let store = BaselineStore(game: game)

        // No lock on purpose: status has to stay usable for diagnosing a
        // session that is holding one.
        let storefront = candidate.sources.joined(separator: "+")
        print("Game        \(game.root.path)   (\(storefront), \(candidate.version))")

        guard let manifest = try store.publishedManifest() else {
            print("Baseline    none — run: archive-loader setup")
            throw CLIError.usage("no baseline captured")
        }

        let versionNote = manifest.gameVersion == candidate.version
            ? ""
            : "  ** recorded \(manifest.gameVersion); run setup --rebaseline **"
        print("Baseline    \(manifest.archives.count) archives, captured \(manifest.capturedAt)\(versionNote)")

        let comparison = try store.compareLive(deep: deep)
        let evidence = try NegativeEvidence.inspect(game: game)
        let artifacts = evidence.findings.filter {
            if case .publishedBaseline = $0 { return false }
            return true
        }

        if comparison.isPristine && artifacts.isEmpty {
            print("Live        pristine — no loader artifacts present"
                + (deep ? "" : "  (sizes only; use --deep to re-hash)"))
        } else {
            print("Live        NOT pristine")
            for path in comparison.drifted {
                print("  differs   \(path)")
            }
            for path in comparison.missing {
                print("  missing   \(path)   ** the baseline can no longer be fully restored **")
            }
            for finding in artifacts {
                print("  artifact  \(finding.description)")
            }
        }

        // Expected, not evidence of tampering: the official archive set is
        // user-dependent and can grow after capture when a language pack or
        // Phantom Liberty is installed.
        for path in comparison.unrecorded {
            print("  extra     \(path)   (not recorded; left alone)")
        }

        let mods = try ModCollection.enabledMods(game: game)
        print("Mods        \(mods.count) enabled")

        // Reported, never judged. A cached generation says a previous run
        // patched successfully; it says nothing about this install's state
        // now, so it must not affect the pristine verdict below.
        let generations = (try? FileManager.default.contentsOfDirectory(
            atPath: game.cacheDirectory.path
        ))?.filter { !$0.hasPrefix(".") }.count ?? 0
        print("Cache       \(generations) patched image\(generations == 1 ? "" : "s")")

        if GameProcess.isRunning(game: game) {
            print("Game        RUNNING — archives are patched for this session")
        }

        guard comparison.isPristine && artifacts.isEmpty else {
            throw CLIError.usage("this installation is not pristine; run: archive-loader restore")
        }
    }
}
