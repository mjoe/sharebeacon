import AppKit
import Foundation

enum AppMetadata {
    static let projectURL = URL(string: "https://github.com/mjoe/sharebeacon")!
    static let websiteURL = URL(string: "https://mjoe.github.io/sharebeacon/")!

    static var aboutCredits: NSAttributedString {
        NSAttributedString(
            string: "mjoe.github.io/sharebeacon",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .link: websiteURL
            ]
        )
    }

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
