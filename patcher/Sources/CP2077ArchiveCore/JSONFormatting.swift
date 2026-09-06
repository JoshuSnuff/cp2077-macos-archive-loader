import Foundation

extension JSONEncoder {
    /// Stable, human-readable JSON for everything the loader writes to disk.
    ///
    /// Sorted keys matter: `baseline.json` and `artifacts.json` are read by
    /// people diagnosing a broken install, and diffed by tests.
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
