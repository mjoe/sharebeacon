import AppKit
import SwiftUI

@main
struct MountJockeyApp: App {
    @StateObject private var shareManager = SMBShareManager()

    var body: some Scene {
        MenuBarExtra("MountJockey", systemImage: menuBarSymbol) {
            Text("MountJockey")
                .font(.headline)

            Divider()

            if shareManager.shares.isEmpty {
                Text("No shares configured")
            } else {
                ForEach(shareManager.shares) { share in
                    Menu {
                        Button("Mount Now") {
                            shareManager.mount(share)
                        }
                        .disabled(
                            shareManager.state(for: share) == .mounted ||
                            !share.isEnabled
                        )

                        Button("Unmount") {
                            shareManager.unmount(share)
                        }
                        .disabled(shareManager.state(for: share) != .mounted)

                        Button("Open in Finder") {
                            shareManager.openInFinder(share)
                        }
                        .disabled(shareManager.state(for: share) != .mounted)

                        Divider()

                        Button(share.isEnabled ? "Disable" : "Enable") {
                            shareManager.setEnabled(!share.isEnabled, for: share)
                        }
                    } label: {
                        Label(
                            "\(share.name) — \(shareManager.state(for: share).label)",
                            systemImage: shareManager.state(for: share).symbolName
                        )
                    }
                }
            }

            Divider()

            Button("Mount All") {
                shareManager.mountAll()
            }

            Button("Preferences…") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",")

            Button("View Log") {
                shareManager.openLog()
            }

            Divider()

            Button("Quit MountJockey") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(shareManager)
        }
    }

    private var menuBarSymbol: String {
        if shareManager.shares.contains(where: {
            if case .failed = shareManager.state(for: $0) { return true }
            return false
        }) {
            return "externaldrive.badge.exclamationmark"
        }
        if shareManager.shares.contains(where: {
            shareManager.state(for: $0) == .mounted
        }) {
            return "externaldrive.fill.badge.checkmark"
        }
        return "externaldrive.badge.wifi"
    }
}
