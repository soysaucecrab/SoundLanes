// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SoundLanes",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "soundlanes", targets: ["soundlanes"]),
        .executable(name: "SoundLanesApp", targets: ["SoundLanesApp"]),
        .library(name: "RouteCore", targets: ["RouteCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "RouteCore"),
        .executableTarget(
            name: "soundlanes",
            dependencies: [
                "RouteCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            linkerSettings: [
                // Embed Info.plist so TCC can show NSAudioCaptureUsageDescription (SPEC §3.4).
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ]),
            ]
        ),
        // Menu bar app. Bundled and signed by scripts/bundle-app.sh (Info.plist lives in the bundle).
        .executableTarget(name: "SoundLanesApp", dependencies: ["RouteCore"]),
        .testTarget(name: "RouteCoreTests", dependencies: ["RouteCore"]),
    ]
)
