import Foundation

enum AppMetadata {
    static let projectURL = URL(string: "https://github.com/mjoe/sharebeacon")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
    }

    static var versionLabel: String {
        "Version \(version) (build \(build))"
    }
}
