// swift-tools-version: 6.2
// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi

import PackageDescription

let package = Package(
    name: "spfk-loudness",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
    ],
    products: [
        .library(
            name: "SPFKLoudness",
            targets: [
                "SPFKLoudness",
                "SPFKLoudnessC",
            ]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/ryanfrancesconi/spfk-audio-base", branch: "development"),
        .package(url: "https://github.com/ryanfrancesconi/spfk-base", branch: "development"),
        .package(url: "https://github.com/ryanfrancesconi/spfk-testing", branch: "development"),
        .package(url: "https://github.com/ryanfrancesconi/spfk-utils", branch: "development"),

    ],
    targets: [
        .target(
            name: "SPFKLoudness",
            dependencies: [
                "SPFKLoudnessC",
                .product(name: "SPFKAudioBase", package: "spfk-audio-base"),
                .product(name: "SPFKBase", package: "spfk-base"),
                .product(name: "SPFKUtils", package: "spfk-utils"),
            ]
        ),

        .target(
            name: "SPFKLoudnessC",
            dependencies: [
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include_private")
            ],
            cxxSettings: [
                .headerSearchPath("include_private")
            ]
        ),

        .testTarget(
            name: "SPFKLoudnessTests",
            dependencies: [
                "SPFKLoudness",
                "SPFKLoudnessC",
                .product(name: "SPFKTesting", package: "spfk-testing"),
            ]
        ),
    ]
)
