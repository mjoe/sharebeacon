import AppKit
import SwiftUI

/// Owns the share manager so that `sharebeacon://` links reach it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let shareManager = SMBShareManager()
    var showSettings: ((SettingsTab) -> Void)?

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let command = ShareBeaconCommand(url: url) else {
                AppLogger.shared.record("Ignored unknown link \(url.absoluteString).", level: .warning)
                continue
            }
            AppLogger.shared.record("Running \(url.absoluteString).", level: .info)
            switch command {
            case .settings: openSettings(.shares)
            case .log: openSettings(.log)
            default: shareManager.perform(command)
            }
        }
    }

    /// Before the menu panel has been shown once there is no view to open
    /// Settings with, so the tab is stored and the standard action is sent.
    private func openSettings(_ tab: SettingsTab) {
        if let showSettings {
            showSettings(tab)
            return
        }
        UserDefaults.standard.set(tab.rawValue, forKey: "selectedSettingsTab")
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

@main
struct ShareBeaconApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var shareManager: SMBShareManager { appDelegate.shareManager }

    var body: some Scene {
        MenuBarExtra("ShareBeacon", systemImage: menuBarSymbol) {
            MenuPanelView()
                .environment(shareManager)
                .background(SettingsOpenerBridge(appDelegate: appDelegate))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(shareManager)
        }
        .windowResizability(.contentMinSize)
    }

    private var menuBarSymbol: String {
        if shareManager.shares.contains(where: {
            if case .failed = shareManager.state(for: $0) { return true }
            return false
        }) || shareManager.shares.contains(where: shareManager.isOnUnexpectedLink) {
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

/// Hands the delegate a way to open Settings, which only a view can do.
private struct SettingsOpenerBridge: View {
    let appDelegate: AppDelegate
    @Environment(\.openSettings) private var openSettings
    @AppStorage("selectedSettingsTab") private var selectedSettingsTab = SettingsTab.shares.rawValue

    var body: some View {
        Color.clear
            .onAppear {
                appDelegate.showSettings = { tab in
                    selectedSettingsTab = tab.rawValue
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
            }
    }
}
