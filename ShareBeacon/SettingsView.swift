import AppKit
import ServiceManagement
import SwiftUI

enum SettingsTab: String {
    case shares
    case general
    case log
}

struct SettingsView: View {
    @Environment(SMBShareManager.self) private var manager
    @AppStorage("selectedSettingsTab") private var selectedTab = SettingsTab.shares.rawValue
    @State private var selection: ShareConfiguration.ID?
    @State private var editedShare: ShareConfiguration?
    @State private var sharePendingRemoval: ShareConfiguration?
    @State private var isAddingShare = false
    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        TabView(selection: $selectedTab) {
            sharesTab
                .tabItem { Label("Shares", systemImage: "externaldrive") }
                .tag(SettingsTab.shares.rawValue)

            LogsView()
                .environment(AppLogger.shared)
                .tabItem { Label("Log", systemImage: "doc.text") }
                .tag(SettingsTab.log.rawValue)

            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general.rawValue)
        }
        .tabViewStyle(.tabBarOnly)
        .frame(minWidth: 640, minHeight: 520)
    }

    private var sharesTab: some View {
        Group {
            if manager.shares.isEmpty {
                ContentUnavailableView {
                    Label("No Shares", systemImage: "externaldrive.badge.plus")
                } description: {
                    Text("Add an SMB share to begin.")
                } actions: {
                    Button("Add Share") {
                        isAddingShare = true
                    }
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
                    Section {
                        Button {
                            isAddingShare = true
                        } label: {
                            Label("Add Share", systemImage: "plus")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                    } footer: {
                        Text("Mounts begin only after the configured SMB endpoint is reachable.")
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
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
                availableSharedCredentials: { manager.sharedCredentials(forHost: $0) },
                updateCredential: { credential, password in
                    try manager.updateSharedCredential(credential, password: password)
                },
                deleteCredential: { credential in
                    try manager.deleteSharedCredential(credential)
                }
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
                availableSharedCredentials: { manager.sharedCredentials(forHost: $0) },
                updateCredential: { credential, password in
                    try manager.updateSharedCredential(credential, password: password)
                },
                deleteCredential: { credential in
                    try manager.deleteSharedCredential(credential)
                }
            ) { share, password in
                try manager.saveShare(share, password: password)
            }
        }
    }

    private var generalTab: some View {
        Form {
            Section {
                Toggle(isOn: launchAtLoginBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at Login")
                        Text("Start ShareBeacon automatically when you sign in.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                LabeledContent("Version") {
                    Text(AppMetadata.versionLabel)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 640, minHeight: 440)
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
                    if share.isEnabled && share.autoMount {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Mounts automatically when available")
                    } else if share.isEnabled {
                        Image(systemName: "hand.tap")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Mounts on demand only")
                    }
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

            primaryActionButton

            Menu {
                Toggle("Share is active", isOn: enabledBinding)
                Toggle("Mount automatically", isOn: autoMountBinding)
                Divider()
                Button("Open in Finder", action: open)
                    .disabled(state != .mounted)
                Button("Add to Finder Favorites", action: favorite)
                    .disabled(state != .mounted)
                Divider()
                Button("Edit…", action: edit)
                Button("Remove…", role: .destructive, action: remove)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .help("More actions")
        }
        .padding(.vertical, 6)
        .help("Double-click to edit")
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        switch state {
        case .mounted:
            Button("Unmount", action: unmount)
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .disabled:
            Button("Mount", action: mount)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(true)
        case .waitingForNetwork, .mounting, .unmounting:
            ProgressView()
                .controlSize(.small)
                .frame(width: 64)
        case .unmounted, .failed:
            Button("Mount", action: mount)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
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
    @State private var newSharedPassword = ""
    @State private var isUpdatingSharedCredential = false
    @State private var credentialPendingDeletion: SharedCredential?
    let availableSharedCredentials: (String) -> [SharedCredential]
    let updateCredential: (SharedCredential, String) throws -> Void
    let deleteCredential: (SharedCredential) throws -> Void
    let onSave: (ShareConfiguration, String?) throws -> Void

    private let defaultMountPoint =
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Volumes")
            .path

    init(
        share: ShareConfiguration,
        availableSharedCredentials: @escaping (String) -> [SharedCredential],
        updateCredential: @escaping (SharedCredential, String) throws -> Void,
        deleteCredential: @escaping (SharedCredential) throws -> Void,
        onSave: @escaping (ShareConfiguration, String?) throws -> Void
    ) {
        _share = State(initialValue: share)
        self.availableSharedCredentials = availableSharedCredentials
        self.updateCredential = updateCredential
        self.deleteCredential = deleteCredential
        self.onSave = onSave
    }

    private var ownCredential: SharedCredential {
        SharedCredential(host: share.host, username: share.username)
    }

    private var credentialOptions: [SharedCredential?] {
        var options: [SharedCredential?] = [nil]
        if availableCredentials.contains(ownCredential) {
            options.append(contentsOf: availableCredentials)
        } else {
            options.append(ownCredential)
            options.append(contentsOf: availableCredentials)
        }
        return options
    }

    private var showsCredentialFields: Bool {
        guard let credential = share.sharedCredential else { return true }
        return !availableCredentials.contains(credential)
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
            return "Store a password for this share only"
        }
        return "\(credential.username)@\(credential.host)"
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
                Picker("Credential", selection: credentialBinding) {
                    ForEach(credentialOptions, id: \.self) { credential in
                        Text(credentialOptionLabel(credential)).tag(credential)
                    }
                }
                if showsCredentialFields {
                    TextField("Username", text: $share.username)
                        .textContentType(.username)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } else if let shared = share.sharedCredential {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Uses the shared Keychain credential for \(shared.username)@\(shared.host).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Button("Update Password…") {
                                newSharedPassword = ""
                                isUpdatingSharedCredential = true
                            }
                            Button("Delete…", role: .destructive) {
                                credentialPendingDeletion = shared
                            }
                        }
                        .font(.caption)
                        .controlSize(.small)
                    }
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
        .alert("Update Shared Credential", isPresented: $isUpdatingSharedCredential) {
            SecureField("New password", text: $newSharedPassword)
            Button("Update") {
                guard let shared = share.sharedCredential,
                      !newSharedPassword.isEmpty else { return }
                do {
                    try updateCredential(shared, newSharedPassword)
                    refreshCredentials()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Set a new password for \(share.sharedCredential.map { "\($0.username)@\($0.host)" } ?? "this credential")."
            )
        }
        .alert(
            "Delete Shared Credential?",
            isPresented: Binding(
                get: { credentialPendingDeletion != nil },
                set: { if !$0 { credentialPendingDeletion = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let shared = credentialPendingDeletion {
                    do {
                        try deleteCredential(shared)
                        share.sharedCredential = nil
                        refreshCredentials()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                credentialPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                credentialPendingDeletion = nil
            }
        } message: {
            Text("Entries that use this credential will require a new password. This cannot be undone.")
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
