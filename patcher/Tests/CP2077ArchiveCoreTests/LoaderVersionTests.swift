import CP2077ArchiveCore
import Testing

@Test func loaderVersionIsThreeNumericComponents() {
    // setup writes this into baseline.json and assemble.sh cross-checks the
    // staged `version` file against it, so "0.1" or "v0.1.0" would break a
    // release rather than merely read oddly.
    let components = LoaderVersion.components
    #expect(components != nil, "LoaderVersion.current must be MAJOR.MINOR.PATCH")
    #expect(components?.major == 0)
    #expect(components?.minor == 1)
    #expect(components?.patch == 0)
    #expect(LoaderVersion.current == "0.1.0")
}

@Test func malformedVersionsHaveNoComponents() {
    #expect(LoaderVersion.parse("0.1") == nil)
    #expect(LoaderVersion.parse("v0.1.0") == nil)
    #expect(LoaderVersion.parse("0.1.0-beta") == nil)
    #expect(LoaderVersion.parse("") == nil)
    #expect(LoaderVersion.parse("0.1.0.1") == nil)
    #expect(LoaderVersion.parse("1.2.3")?.major == 1)
}
