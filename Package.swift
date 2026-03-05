// swift-tools-version: 6.2
// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi

import PackageDescription

let package = Package(
    name: "spfk-loudness",
    defaultLocalization: "en",
    platforms: [.macOS(.v12), .iOS(.v15),],
    products: [
        .library(
            name: "SPFKLoudness",
            targets: ["SPFKLoudness"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/ryanfrancesconi/spfk-audio-base", from: "0.0.6"),
        .package(url: "https://github.com/ryanfrancesconi/spfk-testing", from: "0.0.6"),
    ],
    targets: [
        .target(
            name: "SPFKLoudness",
            dependencies: [
                .targetItem(name: "SPFKLoudnessC", condition: nil),
                .product(name: "SPFKAudioBase", package: "spfk-audio-base"),
            ]
        ),
        .target(
            name: "SPFKLoudnessC",
            dependencies: [],
            publicHeadersPath: "include"
        ),
        .testTarget(
            name: "SPFKLoudnessTests",
            dependencies: [
                .targetItem(name: "SPFKLoudness", condition: nil),
                .product(name: "SPFKTesting", package: "spfk-testing"),
            ]
        ),
    ]
)
