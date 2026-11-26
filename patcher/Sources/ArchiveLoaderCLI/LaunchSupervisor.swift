import CP2077ArchiveCore
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// CLI-owned launch wrapper.  The core target retains the original inherited-
/// environment API; the CLI adds the validated framework overlay without
/// changing the user's executable or argv.
enum LaunchSupervisor {
    static func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]? = nil,
        onStarted: (pid_t) -> Void = { _ in },
        signalForwarder: SignalForwarder? = nil
    ) throws -> LaunchOutcome {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw LaunchError.notExecutable(executable)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        if let environment {
            process.environment = environment
        }

        do {
            try process.run()
        } catch {
            throw LaunchError.couldNotStart(executable, "\(error)")
        }
        onStarted(process.processIdentifier)

        let forwarding: SignalForwarder
        let ownsForwarding: Bool
        if let signalForwarder {
            forwarding = signalForwarder
            forwarding.start()
            ownsForwarding = false
        } else {
            forwarding = SignalForwarder(targets: { [process.processIdentifier] })
            forwarding.start()
            ownsForwarding = true
        }
        defer {
            if ownsForwarding {
                forwarding.stop()
            }
        }

        process.waitUntilExit()

        if process.terminationReason == .uncaughtSignal {
            return LaunchOutcome(
                exitCode: process.terminationStatus,
                signalNumber: process.terminationStatus
            )
        }
        return LaunchOutcome(exitCode: process.terminationStatus, signalNumber: nil)
    }
}

struct ActiveFrameworkRuntime {
    let manifest: CompatibilityManifest
    let runtime: FrameworkRuntimeManifest
    let transaction: InstallationTransactionMarker
}

enum FrameworkRuntimeSupport {
    static let allowlistedEnvironmentKeys: Set<String> = [
        "DYLD_INSERT_LIBRARIES",
        "DYLD_FORCE_FLAT_NAMESPACE",
    ]

    static func active(
        game: GameInstall,
        requireFramework: Bool = false
    ) throws -> ActiveFrameworkRuntime? {
        let inspection = try game.installationTransactionService.inspect()
        guard let transaction = inspection.current else {
            if requireFramework {
                throw CLIError.usage(
                    "framework-dependent mods require an installed compatibility runtime;"
                        + " pass --runtime-package to setup first"
                )
            }
            return nil
        }

        let manifestURL = game.compatibilityManifestURL
        guard FileManager.default.isReadableFile(atPath: manifestURL.path) else {
            throw CLIError.usage(
                "the compatibility runtime transaction is active but its manifest is missing"
            )
        }
        let manifest = try CompatibilityManifest.load(from: manifestURL)
        let identity = try CompatibilityIdentityReader.read(root: game.root, manifest: manifest)
        try CompatibilityIdentityValidator.requireMatch(
            target: manifest.target,
            actual: identity
        )

        guard let runtime = manifest.frameworkRuntime else {
            if requireFramework {
                throw CLIError.usage(
                    "framework-dependent mods require a framework runtime package;"
                        + " install one with setup --runtime-package PATH"
                )
            }
            return nil
        }
        try validateInstalledRuntime(manifest: manifest, game: game)
        return ActiveFrameworkRuntime(
            manifest: manifest,
            runtime: runtime,
            transaction: transaction
        )
    }

    private static func validateInstalledRuntime(
        manifest: CompatibilityManifest,
        game: GameInstall
    ) throws {
        try manifest.validate()
        for role in FrameworkRuntimeRole.required {
            let mappings = manifest.managedFiles.filter { $0.gamePath == role.nativeGamePath }
            guard mappings.count == 1, let mapping = mappings.first else {
                throw CLIError.usage(
                    "installed compatibility runtime is missing the " + role.rawValue + " mapping"
                )
            }

            let destination = try installedRuntimePath(mapping.gamePath, game: game)
            var current = game.root.standardizedFileURL
            for component in mapping.gamePath.split(separator: "/") {
                current.appendPathComponent(String(component), isDirectory: false)
                let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard values.isSymbolicLink != true else {
                    throw CLIError.usage(
                        "installed compatibility runtime path is symlinked: \(destination.path)"
                    )
                }
            }

            let values = try destination.resourceValues(
                forKeys: [.isSymbolicLinkKey, .isRegularFileKey]
            )
            guard FileManager.default.fileExists(atPath: destination.path),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true
            else {
                throw CLIError.usage(
                    "installed compatibility runtime role is not a regular file: \(destination.path)"
                )
            }

            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            guard permissions & 0o111 != 0 else {
                throw CLIError.usage(
                    "installed compatibility runtime role is not executable: \(destination.path)"
                )
            }

            let actualHash = try Hashes.sha256Hex(ofFileAt: destination)
            guard actualHash == mapping.sha256 else {
                throw CLIError.usage(
                    "installed compatibility runtime role hash mismatch: \(destination.path)"
                )
            }

            do {
                _ = try CompatibilityPreflight.run(
                    "codesign",
                    ["--verify", "--deep", "--strict", destination.path]
                )
            } catch {
                throw CLIError.usage(
                    "installed compatibility runtime role failed code-signing validation: \(destination.path)"
                )
            }

            do {
                if try CompatibilityPreflight.hasQuarantine(destination) {
                    throw CLIError.usage(
                        "installed compatibility runtime role is quarantined: \(destination.path)"
                    )
                }
            } catch let error as CLIError {
                throw error
            } catch {
                throw CLIError.usage(
                    "could not inspect quarantine state for installed compatibility runtime role: \(destination.path)"
                )
            }
        }
    }

    static func environment(
        for runtime: FrameworkRuntimeManifest,
        game: GameInstall,
        inherited: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> [String: String] {
        guard Set(runtime.environment.keys) == allowlistedEnvironmentKeys else {
            throw CLIError.usage("compatibility runtime contains an unallowlisted environment key")
        }

        var result = inherited
        for key in allowlistedEnvironmentKeys.sorted() {
            guard let entry = runtime.environment[key] else {
                throw CLIError.usage("compatibility runtime is missing environment key " + key)
            }
            switch (key, entry.mode) {
            case ("DYLD_INSERT_LIBRARIES", "prepend"):
                guard let paths = entry.paths, !paths.isEmpty, entry.value == nil else {
                    throw CLIError.usage("invalid DYLD_INSERT_LIBRARIES runtime overlay")
                }
                let resolved = try paths.map {
                    try runtimePath($0, game: game).path
                }
                let prefix = resolved.joined(separator: ":")
                if let existing = inherited[key], !existing.isEmpty {
                    result[key] = prefix + ":" + existing
                } else {
                    result[key] = prefix
                }

            case ("DYLD_FORCE_FLAT_NAMESPACE", "replace"):
                guard entry.paths == nil, entry.value == "1" else {
                    throw CLIError.usage("invalid DYLD_FORCE_FLAT_NAMESPACE runtime overlay")
                }
                result[key] = "1"

            default:
                throw CLIError.usage("invalid compatibility runtime environment overlay for " + key)
            }
        }
        return result
    }

    private static func runtimePath(_ path: String, game: GameInstall) throws -> URL {
        let resolved = try installedRuntimePath(path, game: game)
        guard FileManager.default.isExecutableFile(atPath: resolved.path) else {
            throw CLIError.usage("runtime environment path is not executable: " + path)
        }
        return resolved
    }

    private static func installedRuntimePath(_ path: String, game: GameInstall) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else {
            throw CLIError.usage("runtime path is not game-root relative: " + path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CLIError.usage("runtime path escapes the game root: " + path)
        }
        let root = game.root.standardizedFileURL
        let resolved = root.appending(path: path).standardizedFileURL
        guard resolved.path == root.path || resolved.path.hasPrefix(root.path + "/") else {
            throw CLIError.usage("runtime path escapes the game root: " + path)
        }
        return resolved
    }
}
