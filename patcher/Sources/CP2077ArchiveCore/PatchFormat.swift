/// The version of what `RDARPatcher` and `RDARWriter` produce.
///
/// Bumped by hand whenever a change makes previously written archives
/// something this loader would no longer emit. It is separate from
/// `LoaderVersion` because a patch release must not throw away a warm cache,
/// and a change to the transplant must, even inside one version.
public enum PatchFormat {
    public static let current = 1
}
