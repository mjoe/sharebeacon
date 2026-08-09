import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(SMBShareManager.self) private var manager
    @Environment(\.openWindow) private var openWindow
    @State private var selection: ShareConfiguration.ID?
    @State private var editedShare: ShareConfiguration?
    @State private var sharePendingRemoval: ShareConfiguration?
    @State private var isAddingShare = false
    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        sharesView
            .frame(minWidth: 620, minHeight: 420)
            .background(.ultraThinMaterial)
            .background(TransparentWindowBackground())
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isAddingShare = true
                    } label: {
                        Label("Add Share", systemImage: "plus")
                    }
                    .help("Add an SMB share")
                }
                ToolbarItem(placement: .secondaryAction) {
                    Menu {
                        Toggle("Launch at Login", isOn: launchAtLoginBinding)
                        Divider()
                        Button("View Activity", systemImage: "doc.text") {
                            openWindow(id: "activity")
                        }
                        Button("Open Log File", systemImage: "doc.plaintext") {
                            manager.openLog()
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .help("Settings and diagnostics")
                }
            }
            .alert(
                "Remove Share?",
                isPresented: Binding(
                    get: { sharePendingRemoval != nil },
                    set: { if !$0 { sharePendingRemoval = nil } }
                )
            ) {
                Button("Remove", role: .destructive) {
                    if let share = sharePendingRemoval {
                        manager.removeShare(share)
                    }
                    sharePendingRemoval = nil
                }
                Button("Cancel", role: .cancel) {
                    sharePendingRemoval = nil
                }
            } message: {
                Text("The configuration and stored Keychain password for \"\(sharePendingRemoval?.name ?? "")\" will be removed.")
            }
            .sheet(item: $editedShare) { share in
                ShareEditorView(
                    share: share,
                    availableSharedCredentials: { manager.sharedCredentials(forHost: $0) }
                ) { updated, password in
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
                    ),
                    availableSharedCredentials: { manager.sharedCredentials(forHost: $0) }
                ) { share, password in
                    try manager.saveShare(share, password: password)
                }
            }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchesAtLogin },
            set: { enabled in
                launchesAtLogin = enabled
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    launchesAtLogin = SMAppService.mainApp.status == .enabled
                }
            }
        )
    }

    private var sharesView: some View {
        Group {
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
                            mount: { manager.mount(share, explicit: true) },
                            unmount: { manager.unmount(share) },
                            open: { manager.openInFinder(share) },
                            favorite: { manager.restoreFinderFavorite(share) },
                            edit: { editedShare = share },
                            toggle: { manager.setEnabled(!share.isEnabled, for: share) },
                            setAutoMount: { manager.setAutoMount($0, for: share) },
                            remove: { sharePendingRemoval = share }
                        )
                        .listRowBackground(
                            selection == share.id ? Color.accentColor.opacity(0.14) : nil
                        )
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture().onEnded {
                            selection = share.id
                        })
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            selection = share.id
                            editedShare = share
                        })
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Text("Mounts begin only after the configured SMB endpoint is reachable.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }
}

private final class TransparentWindowHost: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.isOpaque = false
        window?.backgroundColor = .clear
    }
}

private struct TransparentWindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        TransparentWindowHost()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
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
    let setAutoMount: (Bool) -> Void
    let remove: () -> Void

    private var enabledBinding: Binding<Bool> {
        Binding(get: { share.isEnabled }, set: { _ in toggle() })
    }

    private var autoMountBinding: Binding<Bool> {
        Binding(get: { share.autoMount }, set: { setAutoMount($0) })
    }

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
                    if share.isEnabled && !share.autoMount {
                        Text("On demand")
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

            Toggle("Enabled", isOn: enabledBinding)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(share.isEnabled ? "Disable share" : "Enable share")

            Button(role: .destructive) {
                remove()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .help("Remove share")

            Menu {
                Button("Mount Now", action: mount)
                    .disabled(state == .mounted || !share.isEnabled)
                Button("Unmount", action: unmount)
                    .disabled(state != .mounted)
                Button("Open in Finder", action: open)
                    .disabled(state != .mounted)
                Button("Add to Finder Favorites", action: favorite)
                    .disabled(state != .mounted)
                Divider()
                Toggle("Mount automatically", isOn: autoMountBinding)
                Divider()
                Button("Edit…", action: edit)
                Button("Remove…", role: .destructive, action: remove)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.vertical, 6)
        .help("Double-click to edit")
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
    @State private var availableCredentials: [SharedCredential] = []
    @State private var errorMessage: String?
    let availableSharedCredentials: (String) -> [SharedCredential]
    let onSave: (ShareConfiguration, String?) throws -> Void

    private let defaultMountPoint =
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Volumes")
            .path

    init(
        share: ShareConfiguration,
        availableSharedCredentials: @escaping (String) -> [SharedCredential],
        onSave: @escaping (ShareConfiguration, String?) throws -> Void
    ) {
        _share = State(initialValue: share)
        self.availableSharedCredentials = availableSharedCredentials
        self.onSave = onSave
    }

    private var ownCredential: SharedCredential {
        SharedCredential(host: share.host, username: share.username)
    }

    private var credentialOptions: [SharedCredential?] {
        var options: [SharedCredential?] = [nil]
        options.append(ownCredential)
        for credential in availableCredentials where credential != ownCredential {
            options.append(credential)
        }
        return options
    }

    private var showsPasswordField: Bool {
        share.sharedCredential == nil || share.sharedCredential?.username == share.username
    }

    private var credentialBinding: Binding<SharedCredential?> {
        Binding(
            get: { share.sharedCredential },
            set: { newValue in
                if let credential = newValue, credential.username != share.username {
                    share.username = credential.username
                }
                share.sharedCredential = newValue
            }
        )
    }

    private func credentialOptionLabel(_ credential: SharedCredential?) -> String {
        guard let credential else {
            return "Use a separate password for this share"
        }
        if credential == ownCredential {
            return "Save as shared credential for \(credential.username)@\(credential.host)"
        }
        return "Use shared credential for \(credential.username)@\(credential.host)"
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
                Picker("Credentials", selection: credentialBinding) {
                    ForEach(credentialOptions, id: \.self) { credential in
                        Text(credentialOptionLabel(credential)).tag(credential)
                    }
                }
                if showsPasswordField {
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } else if let shared = share.sharedCredential {
                    Text("Reuses the shared credential for \(shared.username)@\(shared.host).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Mount point") {
                    HStack(spacing: 8) {
                        TextField("", text: $share.mountPoint)
                            .labelsHidden()
                        Button("Browse…") {
                            chooseMountPoint()
                        }
                    }
                }
                Toggle("Share is active", isOn: $share.isEnabled)
                Toggle("Mount automatically when available", isOn: $share.autoMount)

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
        .frame(width: 560, height: 560)
        .onAppear {
            refreshCredentials()
        }
        .onChange(of: share.host) { _, newHost in
            refreshCredentials()
            if let credential = share.sharedCredential {
                share.sharedCredential = SharedCredential(
                    host: newHost,
                    username: credential.username
                )
            }
        }
    }

    private func refreshCredentials() {
        availableCredentials = availableSharedCredentials(share.host)
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
