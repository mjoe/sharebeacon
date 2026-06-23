// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MountJockeyCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MountJockeyCore", targets: ["MountJockeyCore"])
    ],
    targets: [
        .target(
            name: "MountJockeyCore",
            path: "jockey",
            exclude: [
                "Assets.xcassets",
                "ContentView.swift",
                "Info.plist",
                "Logger.swift",
                "LogsView.swift",
                "Preview Content",
                "SettingsView.swift",
                "SMBShareManager.swift",
                "jockey.entitlements",
                "jockeyApp.swift"
            ],
            sources: ["MountCore.swift"]
        ),
        .testTarget(
            name: "MountJockeyCoreTests",
            dependencies: ["MountJockeyCore"],
            path: "Tests/MountJockeyCoreTests"
        )
    ]
)
