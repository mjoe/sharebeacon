import AppKit
import Foundation

enum AppMetadata {
    static let projectURL = URL(string: "https://github.com/mjoe/sharebeacon")!

    static var aboutCredits: NSAttributedString {
        let text = NSMutableAttributedString()
        text.append(
            NSAttributedString(
                string: "Project: ",
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )
        )
        text.append(
            NSAttributedString(
                string: "mjoe/sharebeacon",
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .link: projectURL,
                ]
            )
        )
        return text
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
