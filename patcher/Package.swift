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
            path: "Sources/ArchiveLoaderCLI"
        ),
        .testTarget(
            name: "CP2077ArchiveCoreTests",
            dependencies: ["CP2077ArchiveCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
