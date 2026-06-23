import AppKit
import LaunchAtLogin
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var manager: SMBShareManager
    @State private var editedShare: ShareConfiguration?
    @State private var isAddingShare = false

    var body: some View {
        TabView {
            sharesView
                .tabItem {
                    Label("Shares", systemImage: "externaldrive.connected.to.line.below")
                }

            LogsView()
                .tabItem {
                    Label("Logs", systemImage: "doc.text")
                }

            generalView
                .tabItem {
                    Label("General", systemImage: "gear")
                }
        }
        .frame(minWidth: 720, minHeight: 480)
        .sheet(item: $editedShare) { share in
            ShareEditorView(share: share) { updated, password in
                try manager.saveShare(updated, password: password)
            }
        }
        .sheet(isPresented: $isAddingShare) {
            ShareEditorView(
                share: ShareConfiguration(
                    name: "",
                    host: "",
                    shareName: "",
                    username: "",
                    mountPoint: FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Volumes")
                        .path,
                    isEnabled: true
                )
            ) { share, password in
                try manager.saveShare(share, password: password)
            }
        }
    }

    private var sharesView: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Network Shares")
                        .font(.title2.bold())
                    Text("Mounts begin only after the configured SMB endpoint is reachable.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    isAddingShare = true
                } label: {
                    Label("Add Share", systemImage: "plus")
                }
            }
            .padding()

            Divider()

            if manager.shares.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "externaldrive.badge.plus")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text("No Shares")
                        .font(.title2.bold())
                    Text("Add an SMB share to begin.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(manager.shares) { share in
                        ShareSettingsRow(
                            share: share,
                            state: manager.state(for: share),
                            hasPassword: manager.passwordExists(for: share),
                            mount: { manager.mount(share) },
                            unmount: { manager.unmount(share) },
                            open: { manager.openInFinder(share) },
                            edit: { editedShare = share },
                            toggle: { manager.setEnabled(!share.isEnabled, for: share) },
                            remove: { manager.removeShare(share) }
                        )
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var generalView: some View {
        Form {
            Section("Startup") {
                LaunchAtLogin.Toggle("Launch MountJockey at login")
                Text("MountJockey stays in the menu bar and reacts to network and wake events.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Connectivity") {
                Text("MountJockey probes DNS and TCP port 445 on each SMB host. This works over Tailscale, WireGuard, OpenVPN, ordinary LANs, and other routed networks.")
            }

            Section("Diagnostics") {
                Button("Open Log File") {
                    manager.openLog()
                }
                Text(AppLogger.shared.logURL.path)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct ShareSettingsRow: View {
    let share: ShareConfiguration
    let state: ShareRuntimeState
    let hasPassword: Bool
    let mount: () -> Void
    let unmount: () -> Void
    let open: () -> Void
    let edit: () -> Void
    let toggle: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: state.symbolName)
                .font(.title2)
                .foregroundStyle(statusColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(share.name)
                        .font(.headline)
                    if !share.isEnabled {
                        Text("Disabled")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !hasPassword {
                        Label("Password required", systemImage: "key.slash")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Text("smb://\(share.host)/\(share.shareName)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(share.normalizedMountPoint)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if case .failed(let message) = state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer()

            Text(state.label)
                .font(.caption)
                .foregroundStyle(.secondary)

            Menu {
                Button("Mount Now", action: mount)
                    .disabled(state == .mounted || !share.isEnabled)
                Button("Unmount", action: unmount)
                    .disabled(state != .mounted)
                Button("Open in Finder", action: open)
                    .disabled(state != .mounted)
                Divider()
                Button("Edit…", action: edit)
                Button(share.isEnabled ? "Disable" : "Enable", action: toggle)
                Button("Remove", role: .destructive, action: remove)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.vertical, 6)
    }

    private var statusColor: Color {
        switch state {
        case .mounted: return .green
        case .failed: return .red
        case .waitingForNetwork, .mounting, .unmounting: return .orange
        case .disabled, .unmounted: return .secondary
        }
    }
}

private struct ShareEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var share: ShareConfiguration
    @State private var password = ""
    @State private var errorMessage: String?
    let onSave: (ShareConfiguration, String?) throws -> Void

    init(
        share: ShareConfiguration,
        onSave: @escaping (ShareConfiguration, String?) throws -> Void
    ) {
        _share = State(initialValue: share)
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Display name", text: $share.name)
                TextField("Host", text: $share.host)
                TextField("Share", text: $share.shareName)
                TextField("Username", text: $share.username)
                    .textContentType(.username)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                TextField("Mount point", text: $share.mountPoint)
                Toggle("Automatically mount", isOn: $share.isEnabled)

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }

                Text("Passwords are stored only in your macOS login Keychain. Leave the password blank when editing to keep the existing credential.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    do {
                        try onSave(share, password.isEmpty ? nil : password)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    share.host.trimmingCharacters(in: .whitespaces).isEmpty ||
                    share.shareName.trimmingCharacters(in: .whitespaces).isEmpty ||
                    share.mountPoint.trimmingCharacters(in: .whitespaces).isEmpty
                )
            }
            .padding()
        }
        .frame(width: 520, height: 500)
    }
}
