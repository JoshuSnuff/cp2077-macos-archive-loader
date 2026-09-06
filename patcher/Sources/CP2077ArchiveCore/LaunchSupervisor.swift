import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct LaunchOutcome: Sendable, Equatable {
    public let exitCode: Int32
    public let signalNumber: Int32?

    public init(exitCode: Int32, signalNumber: Int32?) {
        self.exitCode = exitCode
        self.signalNumber = signalNumber
    }

    public var wasSignalled: Bool { signalNumber != nil }

    /// The shell convention: a signalled child reports 128 + signal, so a
    /// Ctrl-C is distinguishable from an ordinary exit code 2.
    public var reportableCode: Int32 {
        if let signalNumber { return 128 + signalNumber }
        return exitCode
    }
}

public enum LaunchError: Error, CustomStringConvertible {
    case notExecutable(URL)
    case couldNotStart(URL, String)

    public var description: String {
        switch self {
        case let .notExecutable(url):
            return "\(url.path) is not an executable file"
        case let .couldNotStart(url, reason):
            return "could not start \(url.path): \(reason)"
        }
    }
}

/// Runs the user's launcher as a child and waits for it.
///
/// Never `exec`: that would replace the process that owes the restore. The
/// environment is inherited untouched, which is the whole reason this is a
/// native binary — a shell hop here would strip `DYLD_*` and silently break
/// RED4ext for every user while archive mods kept working.
public enum LaunchSupervisor {
    public static func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        onStarted: (pid_t) -> Void = { _ in }
    ) throws -> LaunchOutcome {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw LaunchError.notExecutable(executable)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        // environment left nil: the child inherits ours verbatim.

        do {
            try process.run()
        } catch {
            throw LaunchError.couldNotStart(executable, "\(error)")
        }
        onStarted(process.processIdentifier)

        let forwarding = ForwardedSignals(to: process.processIdentifier)
        defer { forwarding.stop() }

        process.waitUntilExit()

        if process.terminationReason == .uncaughtSignal {
            return LaunchOutcome(exitCode: process.terminationStatus, signalNumber: process.terminationStatus)
        }
        return LaunchOutcome(exitCode: process.terminationStatus, signalNumber: nil)
    }
}

/// Forwards SIGINT and SIGTERM to the child for as long as it runs.
///
/// A Ctrl-C must end the game and let this process reach its restore, not
/// kill the wrapper and orphan a patched install.
private final class ForwardedSignals {
    private let sources: [DispatchSourceSignal]
    private let previous: [(Int32, sig_t?)]

    init(to pid: pid_t) {
        var sources: [DispatchSourceSignal] = []
        var previous: [(Int32, sig_t?)] = []
        let queue = DispatchQueue(label: "archive-loader.signals")

        for number in [SIGINT, SIGTERM] {
            // The default disposition has to go before a dispatch source can
            // observe the signal.
            previous.append((number, signal(number, SIG_IGN)))
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler {
                kill(pid, number)
            }
            source.resume()
            sources.append(source)
        }

        self.sources = sources
        self.previous = previous
    }

    func stop() {
        for source in sources { source.cancel() }
        for (number, handler) in previous {
            signal(number, handler ?? SIG_DFL)
        }
    }
}
