import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct PreflightReport: Sendable {
    public struct Check: Sendable {
        public let description: String
        public let passed: Bool
        public let detail: String?

        public init(description: String, passed: Bool, detail: String? = nil) {
            self.description = description
            self.passed = passed
            self.detail = detail
        }
    }

    public let checks: [Check]

    public init(checks: [Check]) {
        self.checks = checks
    }

    public var isClean: Bool { checks.allSatisfy(\.passed) }
    public var failures: [Check] { checks.filter { !$0.passed } }
}

public enum Preflight {
    public static func run(
        game: GameInstall,
        architecture: String = currentArchitecture()
    ) -> PreflightReport {
        var checks: [PreflightReport.Check] = []

        checks.append(PreflightReport.Check(
            description: "Apple Silicon (arm64)",
            passed: architecture == "arm64",
            detail: architecture == "arm64" ? nil : "found \(architecture)"
        ))

        checks.append(PreflightReport.Check(
            description: "game directory is writable",
            passed: FileManager.default.isWritableFile(atPath: game.root.path)
        ))

        var cloneDetail: String?
        do {
            try Clone.verifySupport(in: game.loaderDirectory)
        } catch {
            cloneDetail = "\(error)"
        }
        checks.append(PreflightReport.Check(
            description: "filesystem supports copy-on-write clones",
            passed: cloneDetail == nil,
            detail: cloneDetail
        ))

        return PreflightReport(checks: checks)
    }

    /// The machine's architecture as the kernel reports it. Under Rosetta this
    /// says `x86_64`, which is exactly the case the arm64 check exists to
    /// refuse.
    public static func currentArchitecture() -> String {
        var info = utsname()
        guard uname(&info) == 0 else { return "unknown" }
        var machine = info.machine
        return withUnsafeBytes(of: &machine) { raw in
            guard let base = raw.baseAddress else { return "unknown" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }
}
