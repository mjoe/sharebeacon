@preconcurrency import ApplicationServices
import AppKit
import Foundation

protocol FinderSidebarRepairing: Sendable {
    func restoreFavorite(for share: ShareConfiguration) -> Bool
}

struct FinderSidebarRepairer: FinderSidebarRepairing {
    func restoreFavorite(for share: ShareConfiguration) -> Bool {
        let accessibilityOptions = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        guard AXIsProcessTrustedWithOptions(accessibilityOptions) else {
            logWarning("Finder favorite repair needs Accessibility permission.")
            return false
        }

        let path = escapeAppleScriptString(share.normalizedMountPoint)
        let script = """
        tell application "Finder"
            activate
            reveal POSIX file "\(path)"
        end tell
        tell application "System Events"
            tell process "Finder"
                try
                    click menu item "Add to Sidebar" of menu "File" of menu bar 1
                on error
                    click menu item "Zur Seitenleiste hinzufügen" of menu "Ablage" of menu bar 1
                end try
            end tell
        end tell
        """

        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            logError("Could not create Finder favorite AppleScript.")
            return false
        }
        appleScript.executeAndReturnError(&error)
        if let error {
            logError("Finder favorite AppleScript failed: \(error)")
        }
        return error == nil
    }

    private func escapeAppleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
