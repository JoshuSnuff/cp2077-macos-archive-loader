/// The one place the loader's version is written down.
///
/// `setup` records it in `baseline.json`, `--version` prints it, and the
/// release assembly cross-checks the `version` file it stages against it, so a
/// hand-typed release version cannot silently disagree with the shipped binary.
public enum LoaderVersion {
    public static let current = "0.1.0"

    /// `current` split into numeric components, or nil if it is malformed.
    public static var components: (major: Int, minor: Int, patch: Int)? {
        parse(current)
    }

    /// Strict `MAJOR.MINOR.PATCH`: three components, all non-negative integers,
    /// no prefix and no suffix. Anything looser would let a release ship a
    /// version string the manifest reader cannot compare.
    public static func parse(_ value: String) -> (major: Int, minor: Int, patch: Int)? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let number = Int(part) else { return nil }
            return number
        }
        guard numbers.count == 3 else { return nil }
        return (numbers[0], numbers[1], numbers[2])
    }
}
