// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "CodexRelay",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "CodexRelay", targets: ["CodexRelay"])
    ],
    targets: [
        .executableTarget(
            name: "CodexRelay",
            path: "Sources/CodexRelay"
        )
    ],
    swiftLanguageVersions: [.v5]
)
