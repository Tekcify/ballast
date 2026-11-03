// swift-tools-version: 6.2
import PackageDescription

/// Settings every app target shares: main-actor by default, Swift 6 checks.
let appSettings: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .swiftLanguageMode(.v6),
]

// BallastCore holds the rules and data types that do not depend on any one
// operating system, so every platform's app builds on the same logic.
var products: [Product] = []
var targets: [Target] = [
    .target(
        name: "BallastCore",
        path: "Sources/BallastCore",
        swiftSettings: appSettings
    ),
    .testTarget(
        name: "BallastCoreTests",
        dependencies: ["BallastCore"],
        path: "Tests/BallastCoreTests",
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
]

// Each platform's app is only part of the package on that platform, so
// `swift build` produces the app for the machine it runs on.
#if os(macOS)
products.append(.executable(name: "Ballast", targets: ["BallastMac"]))
targets += [
    .executableTarget(
        name: "BallastMac",
        dependencies: ["BallastCore"],
        path: "Sources/BallastMac",
        swiftSettings: appSettings
    ),
    .testTarget(
        name: "BallastMacTests",
        dependencies: ["BallastCore", "BallastMac"],
        path: "Tests/BallastMacTests",
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
]
#endif

let package = Package(
    name: "Ballast",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
