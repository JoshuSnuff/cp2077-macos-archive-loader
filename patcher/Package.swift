// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "archive-loader",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "archive-loader", targets: ["archive-loader"]),
        .library(name: "CP2077ArchiveCore", targets: ["CP2077ArchiveCore"]),
    ],
    targets: [
        .target(
            name: "CP2077ArchiveCore"
        ),
        .executableTarget(
            name: "archive-loader",
            dependencies: ["CP2077ArchiveCore"],
            path: "Sources/ArchiveLoaderCLI",
            linkerSettings: [
                // dyld ignores DYLD_* for any binary carrying a __RESTRICT
                // segment. Without this, a DYLD_INSERT_LIBRARIES exported from
                // a shell profile loads RED4ext and Frida into the wrapper
                // itself, and red4ext_hooks.js then applies raw game-build
                // 2.3.1 __TEXT offsets to our address space. It cannot be
                // defended against from inside, because the dylibs load before
                // main. tests/restrict_section_test.sh is the only thing that
                // would notice this flag going missing.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__RESTRICT",
                    "-Xlinker", "__restrict",
                    "-Xlinker", "/dev/null",
                ])
            ]
        ),
        .testTarget(
            name: "CP2077ArchiveCoreTests",
            dependencies: ["CP2077ArchiveCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
