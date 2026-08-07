import AppKit
import SwiftUI

@main
struct ShareBeaconApp: App {
    @State private var shareManager = SMBShareManager()

    var body: some Scene {
        MenuBarExtra("ShareBeacon", systemImage: menuBarSymbol) {
            Text("ShareBeacon")
                .font(.headline)
            Text(AppMetadata.versionLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            if shareManager.shares.isEmpty {
                Text("No shares configured")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(shareManager.shares) { share in
                    Menu {
                        Button("Mount Now", systemImage: "play.fill") {
                            shareManager.mount(share)
                        }
                        .disabled(
                            shareManager.state(for: share) == .mounted ||
                            !share.isEnabled
                        )

                        Button("Unmount", systemImage: "eject") {
                            shareManager.unmount(share)
                        }
                        .disabled(shareManager.state(for: share) != .mounted)

                        Button("Open in Finder", systemImage: "folder") {
                            shareManager.openInFinder(share)
                        }
                        .disabled(shareManager.state(for: share) != .mounted)

                        Button("Add to Finder Favorites", systemImage: "star") {
                            shareManager.restoreFinderFavorite(share)
                        }
                        .disabled(shareManager.state(for: share) != .mounted)

                        Divider()

                        Button(
                            share.isEnabled ? "Disable Share" : "Enable Share",
                            systemImage: share.isEnabled ? "pause.circle" : "play.circle"
                        ) {
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

            Button("Mount All", systemImage: "externaldrive.badge.checkmark") {
                shareManager.mountAll()
            }
            .disabled(!hasSharesWaitingToMount)

            SettingsLink {
                Label("Preferences…", systemImage: "gear")
            }
            .keyboardShortcut(",")

            Button("View Log", systemImage: "doc.text") {
                shareManager.openLog()
            }

            Divider()

            Button("Quit ShareBeacon", systemImage: "power") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(shareManager)
        }
    }

    private var hasSharesWaitingToMount: Bool {
        shareManager.shares.contains {
            shareManager.state(for: $0) != .mounted && $0.isEnabled
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
