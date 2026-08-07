@preconcurrency import ApplicationServices
import AppKit
import Foundation

protocol FinderSidebarRepairing: Sendable {
    func restoreFavorite(for share: ShareConfiguration) -> Bool
}

struct FinderSidebarRepairer: FinderSidebarRepairing {
    func restoreFavorite(for share: ShareConfiguration) -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            logWarning("Finder favorite repair needs Accessibility permission.")
            return false
        }

        let mountURL = URL(fileURLWithPath: share.normalizedMountPoint, isDirectory: true)
        guard NSWorkspace.shared.open(mountURL) else {
            logError("Could not open mounted share in Finder.")
            return false
        }
        Thread.sleep(forTimeInterval: 0.5)

        guard
            let finder = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.finder"
            ).first
        else {
            logError("Could not find the Finder application.")
            return false
        }

        let application = AXUIElementCreateApplication(finder.processIdentifier)
        guard let menuBar = attribute(kAXMenuBarAttribute as CFString, of: application) else {
            logError("Could not access the Finder menu bar.")
            return false
        }

        let fileMenu = descendant(
            titled: ["File", "Ablage"],
            in: menuBar
        )
        guard let fileMenu else {
            logError("Could not find the Finder File menu.")
            return false
        }
        guard AXUIElementPerformAction(fileMenu, kAXPressAction as CFString) == .success else {
            logError("Could not open the Finder File menu.")
            return false
        }
        Thread.sleep(forTimeInterval: 0.2)

        guard let addItem = descendant(
            titled: ["Add to Sidebar", "Zur Seitenleiste hinzufügen"],
            in: menuBar
        ) else {
            logError("Could not find Finder's Add to Sidebar menu item.")
            return false
        }
        guard AXUIElementPerformAction(addItem, kAXPressAction as CFString) == .success else {
            logError("Could not activate Finder's Add to Sidebar menu item.")
            return false
        }
        return true
    }

    private func attribute(_ name: CFString, of element: AXUIElement) -> AXUIElement? {
        value(name, of: element) as! AXUIElement
    }

    private func descendant(titled titles: [String], in element: AXUIElement) -> AXUIElement? {
        if let title = attributeValue(kAXTitleAttribute as CFString, of: element), titles.contains(title) {
            return element
        }
        guard let elements = value(kAXChildrenAttribute as CFString, of: element) as? [AXUIElement] else { return nil }
        for child in elements {
            if let match = descendant(titled: titles, in: child) { return match }
        }
        return nil
    }

    private func attributeValue(_ name: CFString, of element: AXUIElement) -> String? {
        value(name, of: element) as? String
    }

    private func value(_ name: CFString, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }
}
