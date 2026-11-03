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
        dependencies: ["BallastMac"],
        path: "Tests/BallastMacTests",
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
]
#elseif os(Windows)
products += [
    .executable(name: "Ballast", targets: ["BallastWindows"]),
    .executable(name: "BallastDiagnostic", targets: ["BallastDiagnostic"]),
]
targets += [
    // The Windows platform layer: Win32 probes, grouping, quitting, login item.
    .target(
        name: "BallastWindowsKit",
        dependencies: ["BallastCore"],
        path: "Sources/BallastWindowsKit",
        swiftSettings: appSettings,
        linkerSettings: [
            .linkedLibrary("User32"),
            .linkedLibrary("Advapi32"),
            .linkedLibrary("Version"),
        ]
    ),
    // The tray app. Linked as a GUI program so no console window opens.
    .executableTarget(
        name: "BallastWindows",
        dependencies: ["BallastCore", "BallastWindowsKit"],
        path: "Sources/BallastWindows",
        swiftSettings: appSettings,
        linkerSettings: [
            .linkedLibrary("User32"),
            .linkedLibrary("Shell32"),
            .unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"]),
        ]
    ),
    // A console tool that prints one snapshot, like BALLAST_DIAGNOSTIC=1 on the Mac.
    .executableTarget(
        name: "BallastDiagnostic",
        dependencies: ["BallastCore", "BallastWindowsKit"],
        path: "Sources/BallastDiagnostic",
        swiftSettings: appSettings
    ),
    .testTarget(
        name: "BallastWindowsKitTests",
        dependencies: ["BallastCore", "BallastWindowsKit"],
        path: "Tests/BallastWindowsKitTests",
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
