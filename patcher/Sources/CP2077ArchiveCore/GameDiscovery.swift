import Foundation

public struct GameCandidate: Sendable, Equatable {
    public let root: URL
    public let version: String
    public let sources: [String]

    public init(root: URL, version: String, sources: [String]) {
        self.root = root
        self.version = version
        self.sources = sources
    }
}

public struct GameDiscoveryLocations: Sendable {
    public let homeDirectory: URL
    public let steamRoot: URL
    public let gogApplicationsDirectory: URL
    public let heroicDataDirectories: [URL]
    public let conventionalCandidates: [URL]
    public let boundedSearchRoots: [URL]
    public let maximumSearchDepth: Int

    public init(
        homeDirectory: URL,
        steamRoot: URL,
        gogApplicationsDirectory: URL,
        heroicDataDirectories: [URL],
        conventionalCandidates: [URL],
        boundedSearchRoots: [URL],
        maximumSearchDepth: Int = 4
    ) {
        self.homeDirectory = homeDirectory
        self.steamRoot = steamRoot
        self.gogApplicationsDirectory = gogApplicationsDirectory
        self.heroicDataDirectories = heroicDataDirectories
        self.conventionalCandidates = conventionalCandidates
        self.boundedSearchRoots = boundedSearchRoots
        self.maximumSearchDepth = maximumSearchDepth
    }

    public static func system(fileManager: FileManager = .default) -> GameDiscoveryLocations {
        let home = fileManager.homeDirectoryForCurrentUser
        let applicationSupport = home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        let steam = applicationSupport.appending(path: "Steam", directoryHint: .isDirectory)
        let gogApplications = applicationSupport
            .appending(path: "GOG.com/Galaxy/Applications", directoryHint: .isDirectory)
        let heroic = applicationSupport.appending(path: "heroic", directoryHint: .isDirectory)

        var conventionalCandidates = [
            steam.appending(path: "steamapps/common/Cyberpunk 2077", directoryHint: .isDirectory),
            home.appending(path: "Games/Heroic/Cyberpunk 2077", directoryHint: .isDirectory),
            home.appending(path: "Applications/Cyberpunk 2077", directoryHint: .isDirectory),
            URL(fileURLWithPath: "/Applications/Cyberpunk 2077", isDirectory: true),
        ]
        var boundedRoots = [
            home.appending(path: "Games", directoryHint: .isDirectory),
            home.appending(path: "Applications", directoryHint: .isDirectory),
            URL(fileURLWithPath: "/Applications", isDirectory: true),
        ]

        let volumes = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        if let mountedVolumes = try? fileManager.contentsOfDirectory(
            at: volumes,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for volume in mountedVolumes {
                conventionalCandidates.append(
                    volume.appending(path: "Cyberpunk 2077", directoryHint: .isDirectory)
                )
                boundedRoots.append(volume.appending(path: "Games", directoryHint: .isDirectory))
                boundedRoots.append(volume.appending(path: "Applications", directoryHint: .isDirectory))
            }
        }

        return GameDiscoveryLocations(
            homeDirectory: home,
            steamRoot: steam,
            gogApplicationsDirectory: gogApplications,
            heroicDataDirectories: [heroic],
            conventionalCandidates: conventionalCandidates,
            boundedSearchRoots: boundedRoots
        )
    }
}

public struct GameValidationError: Error, CustomStringConvertible, Sendable {
    public let root: URL
    public let issues: [String]

    public init(root: URL, issues: [String]) {
        self.root = root
        self.issues = issues
    }

    public var description: String {
        "invalid game directory \(root.path): " + issues.joined(separator: "; ")
    }
}

public enum GameDiscovery {
    private static let appName = "Cyberpunk2077.app"
    private static let executableRelativePath = "Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
    private static let infoPlistRelativePath = "Cyberpunk2077.app/Contents/Info.plist"
    private static let contentRelativePath = "archive/Mac/content"

    public static func resolve(
        explicitRoot: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        installedExecutable: URL? = InstalledLayout.currentExecutable(),
        locations: GameDiscoveryLocations = .system(),
        fileManager: FileManager = .default
    ) throws -> [GameCandidate] {
        if let explicitRoot {
            return [try validate(root: explicitRoot, sources: ["explicit"], fileManager: fileManager)]
        }

        if let environmentPath = environment["ARCHIVE_LOADER_GAME_DIR"], !environmentPath.isEmpty {
            return [try validate(
                root: URL(fileURLWithPath: environmentPath, isDirectory: true),
                sources: ["environment"],
                fileManager: fileManager
            )]
        }

        // An installed binary already knows where the game is. A development
        // build does not live inside one, so failing here is the expected case
        // and must fall through to discovery rather than abort.
        if let installedExecutable,
           let candidate = try? validate(
               root: InstalledLayout.gameRoot(forExecutable: installedExecutable),
               sources: ["installed"],
               fileManager: fileManager
           ) {
            return [candidate]
        }

        return discover(locations: locations, fileManager: fileManager)
    }

    public static func discover(
        locations: GameDiscoveryLocations = .system(),
        fileManager: FileManager = .default
    ) -> [GameCandidate] {
        var inputs: [(url: URL, source: String)] = []

        inputs.append(contentsOf: steamCandidates(locations: locations, fileManager: fileManager))
        inputs.append(contentsOf: gogCandidates(locations: locations, fileManager: fileManager))
        inputs.append(contentsOf: heroicCandidates(locations: locations))
        inputs.append(contentsOf: locations.conventionalCandidates.map { ($0, "conventional") })

        for root in locations.boundedSearchRoots {
            inputs.append(contentsOf: boundedCandidates(
                under: root,
                maximumDepth: locations.maximumSearchDepth,
                fileManager: fileManager
            ).map { ($0, "bounded-search") })
        }

        var candidatesByPath: [String: GameCandidate] = [:]
        for input in inputs {
            guard let candidate = try? validate(
                root: input.url,
                sources: [input.source],
                fileManager: fileManager
            ) else {
                continue
            }

            let key = candidate.root.path
            if let existing = candidatesByPath[key] {
                let sources = Array(Set(existing.sources + candidate.sources)).sorted()
                candidatesByPath[key] = GameCandidate(
                    root: existing.root,
                    version: existing.version,
                    sources: sources
                )
            } else {
                candidatesByPath[key] = candidate
            }
        }

        return candidatesByPath.values.sorted { $0.root.path < $1.root.path }
    }

    public static func validate(
        root suppliedRoot: URL,
        sources: [String] = ["explicit"],
        fileManager: FileManager = .default
    ) throws -> GameCandidate {
        let rootBeforeCanonicalization = suppliedRoot.lastPathComponent == appName
            ? suppliedRoot.deletingLastPathComponent()
            : suppliedRoot
        let root = rootBeforeCanonicalization.normalizedFileURL
        let executable = root.appending(path: executableRelativePath)
        let infoPlist = root.appending(path: infoPlistRelativePath)
        let content = root.appending(path: contentRelativePath, directoryHint: .isDirectory)
        var issues: [String] = []

        if !isDirectory(root, fileManager: fileManager) {
            issues.append("directory does not exist")
        }
        if !fileManager.isExecutableFile(atPath: executable.path) {
            issues.append("missing executable \(executableRelativePath)")
        }
        if !fileManager.isReadableFile(atPath: infoPlist.path) {
            issues.append("missing readable \(infoPlistRelativePath)")
        }
        if !isDirectory(content, fileManager: fileManager) {
            issues.append("missing directory \(contentRelativePath)")
        } else if !containsArchive(content, fileManager: fileManager) {
            issues.append("\(contentRelativePath) contains no .archive files")
        }

        let version: String?
        do {
            version = try readVersion(infoPlist: infoPlist)
            if version?.isEmpty != false {
                issues.append("Info.plist has no game version")
            }
        } catch {
            version = nil
            if fileManager.isReadableFile(atPath: infoPlist.path) {
                issues.append("could not parse game version from Info.plist")
            }
        }

        guard issues.isEmpty, let version else {
            throw GameValidationError(root: root, issues: issues)
        }

        return GameCandidate(root: root, version: version, sources: Array(Set(sources)).sorted())
    }

    private static func steamCandidates(
        locations: GameDiscoveryLocations,
        fileManager: FileManager
    ) -> [(URL, String)] {
        var libraryRoots = [locations.steamRoot]
        let libraryFile = locations.steamRoot.appending(path: "steamapps/libraryfolders.vdf")
        if let text = try? String(contentsOf: libraryFile, encoding: .utf8) {
            libraryRoots.append(contentsOf: quotedValues(named: "path", in: text).map {
                URL(fileURLWithPath: unescapeVDF($0), isDirectory: true)
            })
        }

        var results: [(URL, String)] = []
        var seenLibraries: Set<String> = []
        for library in libraryRoots.map(\.normalizedFileURL) where seenLibraries.insert(library.path).inserted {
            let steamapps = library.lastPathComponent == "steamapps"
                ? library
                : library.appending(path: "steamapps", directoryHint: .isDirectory)
            let manifest = steamapps.appending(path: "appmanifest_1091500.acf")
            guard let text = try? String(contentsOf: manifest, encoding: .utf8),
                  let installDirectory = quotedValues(named: "installdir", in: text).first
            else {
                continue
            }
            results.append((
                steamapps.appending(path: "common/\(unescapeVDF(installDirectory))", directoryHint: .isDirectory),
                "steam"
            ))
        }
        return results
    }

    private static func gogCandidates(
        locations: GameDiscoveryLocations,
        fileManager: FileManager
    ) -> [(URL, String)] {
        guard let applications = try? fileManager.contentsOfDirectory(
            at: locations.gogApplicationsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return applications.map { ($0, "gog") }
    }

    private static func heroicCandidates(locations: GameDiscoveryLocations) -> [(URL, String)] {
        let metadataPaths = [
            "gog_store/installed.json",
            "legendaryConfig/legendary/installed.json",
            "nile_config/nile/installed.json",
            "sideload_apps/installed.json",
        ]

        var results: [(URL, String)] = []
        for dataDirectory in locations.heroicDataDirectories {
            for relativePath in metadataPaths {
                let metadata = dataDirectory.appending(path: relativePath)
                guard let data = try? Data(contentsOf: metadata),
                      let object = try? JSONSerialization.jsonObject(with: data)
                else {
                    continue
                }
                for path in installPaths(in: object) {
                    results.append((URL(fileURLWithPath: path, isDirectory: true), "heroic"))
                }
            }
        }
        return results
    }

    private static func installPaths(in object: Any) -> [String] {
        if let dictionary = object as? [String: Any] {
            var paths: [String] = []
            for (key, value) in dictionary {
                let normalizedKey = key.replacingOccurrences(of: "_", with: "").lowercased()
                if normalizedKey == "installpath", let path = value as? String, !path.isEmpty {
                    paths.append(path)
                }
                paths.append(contentsOf: installPaths(in: value))
            }
            return paths
        }
        if let array = object as? [Any] {
            return array.flatMap(installPaths(in:))
        }
        return []
    }

    private static func boundedCandidates(
        under root: URL,
        maximumDepth: Int,
        fileManager: FileManager
    ) -> [URL] {
        guard isDirectory(root, fileManager: fileManager),
              let enumerator = fileManager.enumerator(
                  at: root,
                  includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                  options: [.skipsHiddenFiles, .skipsPackageDescendants]
              )
        else {
            return []
        }

        var results: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            // maximumDepth describes the game root. The app bundle itself is
            // one level below that root and must still be visited.
            if enumerator.level > maximumDepth + 1 {
                enumerator.skipDescendants()
                continue
            }
            if item.lastPathComponent == appName {
                results.append(item.deletingLastPathComponent())
                enumerator.skipDescendants()
            }
        }
        return results
    }

    private static func quotedValues(named key: String, in text: String) -> [String] {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        guard let expression = try? NSRegularExpression(
            pattern: "\"\(escapedKey)\"\\s+\"((?:\\\\.|[^\"])*)\"",
            options: [.caseInsensitive]
        ) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard let valueRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[valueRange])
        }
    }

    private static func unescapeVDF(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\\\", with: "\\")
            .replacingOccurrences(of: "\\\"", with: "\"")
    }

    private static func readVersion(infoPlist: URL) throws -> String? {
        let data = try Data(contentsOf: infoPlist)
        guard let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any]
        else {
            return nil
        }
        return (dictionary["CFBundleShortVersionString"] as? String)
            ?? (dictionary["CFBundleVersion"] as? String)
    }

    private static func containsArchive(_ directory: URL, fileManager: FileManager) -> Bool {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        return entries.contains { $0.pathExtension.lowercased() == "archive" }
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
