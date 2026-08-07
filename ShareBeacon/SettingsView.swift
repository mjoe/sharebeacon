import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(SMBShareManager.self) private var manager
    @State private var editedShare: ShareConfiguration?
    @State private var isAddingShare = false

    var body: some View {
        TabView {
            Tab("Shares", systemImage: "externaldrive.connected.to.line.below") {
                sharesView
            }
            Tab("Activity", systemImage: "doc.text") {
                LogsView()
            }
            Tab("General", systemImage: "gear") {
                generalView
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
                    mountPoint: "~/Volumes",
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
                Text("Shares")
                    .font(.title2.bold())
                Text("\(manager.shares.count) configured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    isAddingShare = true
                } label: {
                    Label("Add Share", systemImage: "plus")
                }
                .buttonStyle(.glassProminent)
            }
            .padding()

            Divider()

            if manager.shares.isEmpty {
                ContentUnavailableView {
                    Label("No Shares", systemImage: "externaldrive.badge.plus")
                } description: {
                    Text("Add an SMB share to begin.")
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
                            favorite: { manager.restoreFinderFavorite(share) },
                            edit: { editedShare = share },
                            toggle: { manager.setEnabled(!share.isEnabled, for: share) },
                            remove: { manager.removeShare(share) }
                        )
                    }
                }
                .listStyle(.inset)
                .safeAreaInset(edge: .bottom) {
                    Text("Mounts begin only after the configured SMB endpoint is reachable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
    }

    private var generalView: some View {
        Form {
            Section {
                LaunchAtLoginControl()
            } header: {
                Text("Startup")
            } footer: {
                Text("ShareBeacon stays in the menu bar and reacts to network and wake events.")
            }

            Section("Diagnostics") {
                Button("Open Log File", systemImage: "doc.text") {
                    manager.openLog()
                }
                LabeledContent("Location") {
                    Text(AppLogger.shared.logURL.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }

            Section("About") {
                LabeledContent("Version") {
                    Text(AppMetadata.versionLabel)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                LabeledContent("License") {
                    Text("MIT")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct LaunchAtLoginControl: View {
    @State private var isEnabled = SMAppService.mainApp.status == .enabled
    @State private var errorMessage: String?

    var body: some View {
        Toggle("Launch ShareBeacon at login", isOn: $isEnabled)
            .onChange(of: isEnabled) { _, enabled in
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    errorMessage = nil
                } catch {
                    isEnabled = SMAppService.mainApp.status == .enabled
                    errorMessage = error.localizedDescription
                }
            }
            .help(errorMessage ?? "")
    }
}

private struct ShareSettingsRow: View {
    let share: ShareConfiguration
    let state: ShareRuntimeState
    let hasPassword: Bool
    let mount: () -> Void
    let unmount: () -> Void
    let open: () -> Void
    let favorite: () -> Void
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
                Button("Mount Now", systemImage: "play.fill", action: mount)
                    .disabled(state == .mounted || !share.isEnabled)
                Button("Unmount", systemImage: "eject", action: unmount)
                    .disabled(state != .mounted)
                Button("Open in Finder", systemImage: "folder", action: open)
                    .disabled(state != .mounted)
                Button("Add to Finder Favorites", systemImage: "star", action: favorite)
                    .disabled(state != .mounted)
                Divider()
                Button("Edit…", systemImage: "pencil", action: edit)
                Button(
                    share.isEnabled ? "Disable" : "Enable",
                    systemImage: share.isEnabled ? "pause.circle" : "play.circle",
                    action: toggle
                )
                Button("Remove…", systemImage: "trash", role: .destructive, action: remove)
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

    private let defaultMountPoint =
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Volumes")
            .path

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
                TextField("Share name", text: $share.shareName)
                    .onChange(of: share.shareName) { _, newValue in
                        suggestMountPointIfDefault(named: newValue)
                    }
                TextField("Username", text: $share.username)
                    .textContentType(.username)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                LabeledContent("Mount point") {
                    HStack(spacing: 8) {
                        TextField("", text: $share.mountPoint)
                            .labelsHidden()
                        Button("Browse…") {
                            chooseMountPoint()
                        }
                    }
                }
                Toggle("Mount automatically when available", isOn: $share.isEnabled)

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
                .buttonStyle(.borderedProminent)
                .disabled(
                    share.name.trimmingCharacters(in: .whitespaces).isEmpty ||
                    share.host.trimmingCharacters(in: .whitespaces).isEmpty ||
                    share.shareName.trimmingCharacters(in: .whitespaces).isEmpty ||
                    share.mountPoint.trimmingCharacters(in: .whitespaces).isEmpty
                )
            }
            .padding()
        }
        .frame(width: 560, height: 520)
    }

    private func suggestMountPointIfDefault(named shareName: String) {
        let trimmed = shareName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard share.mountPoint == defaultMountPoint || share.mountPoint == "~/Volumes" else {
            return
        }
        share.mountPoint = "\(defaultMountPoint)/\(trimmed)"
    }

    private func chooseMountPoint() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        share.mountPoint = url.path
    }
}
