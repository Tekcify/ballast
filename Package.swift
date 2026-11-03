// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Ballast",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Ballast",
            path: "Sources/Ballast",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "BallastTests",
            dependencies: ["Ballast"],
            path: "Tests/BallastTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
