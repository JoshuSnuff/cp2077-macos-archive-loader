import Foundation

/// The two document sets consumed by the offline builder and the runtime
/// projection. Archive payloads are intentionally absent from this partition.
public struct TweakModPartition: Sendable, Equatable {
    public let offline: [URL]
    public let runtimeOwned: [URL]

    public init(offline: [URL], runtimeOwned: [URL]) {
        self.offline = offline
        self.runtimeOwned = runtimeOwned
    }

    public var offlineMods: [URL] { offline }
    public var runtimeMods: [URL] { runtimeOwned }
}

public extension TweakPlanner {
    /// Splits supported tweak documents without changing the legacy planner's
    /// operation or conflict semantics.
    static func partition(
        mods: [URL],
        requirements: ModFrameworkRequirements
    ) -> TweakModPartition {
        let textExtensions = TweakModCollection.supportedExtensions
        let ordered = mods.map(\.normalizedFileURL).filter {
            textExtensions.contains($0.pathExtension.lowercased())
        }.sorted { utf8Precedes($0.path, $1.path) }
        let runtime = Set(requirements.runtimeOwnedMods)
        let runtimeOwned = ordered.filter { runtime.contains($0) }
        let offline = ordered.filter { !runtime.contains($0) }
        return TweakModPartition(offline: offline, runtimeOwned: runtimeOwned)
    }

    /// Plans only the offline subset. Runtime-owned documents are reserved for
    /// the native framework projection and never enter the offline builder.
    static func plan(
        mods: [URL],
        blobs: [URL],
        requirements: ModFrameworkRequirements
    ) throws -> TweakPlan {
        try plan(mods: partition(mods: mods, requirements: requirements).offline, blobs: blobs)
    }
}

private func utf8Precedes(_ left: String, _ right: String) -> Bool {
    Array(left.utf8).lexicographicallyPrecedes(Array(right.utf8))
}

