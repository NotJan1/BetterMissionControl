// swift-tools-version: 6.0
import PackageDescription

// Built with SwiftPM rather than an .xcodeproj so the app compiles with the
// Command Line Tools alone. `build.sh` wraps the binary produced here in a
// proper .app bundle, which is what macOS needs before it will grant the
// Accessibility and Screen Recording permissions this app depends on.
let package = Package(
    name: "BetterMissionControl",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "BetterMissionControl",
            path: "Sources/BetterMissionControl",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
