import AppKit
import SwiftUI

@main
struct ShareBeaconApp: App {
    @State private var shareManager = SMBShareManager()
    @Environment(\.openSettings) private var openSettings
    @AppStorage("selectedSettingsTab") private var selectedSettingsTab = SettingsTab.shares.rawValue

    var body: some Scene {
        MenuBarExtra("ShareBeacon", systemImage: menuBarSymbol) {
            if shareManager.shares.isEmpty {
                Text("No shares configured")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(shareManager.shares) { share in
                    Menu {
                        Button("Mount Now") {
                            shareManager.mount(share, explicit: true)
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

                        Button("Add to Finder Favorites") {
                            shareManager.restoreFinderFavorite(share)
                        }
                        .disabled(shareManager.state(for: share) != .mounted)

                        Divider()

                        Button(share.isEnabled ? "Disable Share" : "Enable Share") {
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
                shareManager.mountAllEnabled()
            }
            .disabled(!hasSharesWaitingToMount)

            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            .keyboardShortcut(",")

            Button("View Log") {
                selectedSettingsTab = SettingsTab.log.rawValue
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }

            Divider()

            Button("About") {
                NSApp.activate(ignoringOtherApps: true)
                NSApplication.shared.orderFrontStandardAboutPanel(nil)
            }

            Button("GitHub Project…") {
                NSApp.activate(ignoringOtherApps: true)
                NSWorkspace.shared.open(AppMetadata.projectURL)
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")

            Divider()

            Text(AppMetadata.versionLabel)
                .foregroundStyle(.secondary)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(shareManager)
        }
    }

    private var hasSharesWaitingToMount: Bool {
        shareManager.shares.contains {
            $0.isEnabled && shareManager.state(for: $0) != .mounted
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
