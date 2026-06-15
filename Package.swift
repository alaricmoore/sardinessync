// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "sardinessync-xtool",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        // An xtool project should contain exactly one library product,
        // representing the main app.
        .library(
            name: "sardinessync_xtool",
            targets: ["sardinessync_xtool"]
        ),
    ],
    targets: [
        .target(
            name: "sardinessync_xtool",
            resources: [.process("Resources")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
