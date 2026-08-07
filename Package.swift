// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShareBeaconCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "ShareBeaconCore", targets: ["ShareBeaconCore"])
    ],
    targets: [
        .target(
            name: "ShareBeaconCore",
            path: "ShareBeacon",
            exclude: [
                "Assets.xcassets",
                "ContentView.swift",
                "Info.plist",
                "Logger.swift",
                "LogsView.swift",
                "Preview Content",
                "SettingsView.swift",
                "SMBShareManager.swift",
                "sharebeacon.entitlements",
                "ShareBeaconApp.swift"
            ],
            sources: ["MountCore.swift"]
        ),
        .testTarget(
            name: "ShareBeaconCoreTests",
            dependencies: ["ShareBeaconCore"],
            path: "Tests/ShareBeaconCoreTests"
        )
    ]
)
