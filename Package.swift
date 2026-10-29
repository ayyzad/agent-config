// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AgentConfig",
    platforms: [.macOS(.v14)],
    targets: [
        // File formats, rule logic, backups. No UI.
        .target(name: "AgentConfigCore"),
        // The Mac app.
        .executableTarget(name: "AgentConfig", dependencies: ["AgentConfigCore"]),
        // `swift run selftest`: checks the core against your real settings files (read-only).
        .executableTarget(name: "selftest", dependencies: ["AgentConfigCore"]),
    ],
    swiftLanguageModes: [.v5]
)
