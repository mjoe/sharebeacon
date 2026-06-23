import AppKit
import Combine
import Foundation
import Network

enum ShareRuntimeState: Equatable {
    case disabled
    case unmounted
    case waitingForNetwork
    case mounting
    case mounted
    case unmounting
    case failed(String)

    var label: String {
        switch self {
        case .disabled: return "Disabled"
        case .unmounted: return "Unmounted"
        case .waitingForNetwork: return "Waiting for network"
        case .mounting: return "Mounting"
        case .mounted: return "Mounted"
        case .unmounting: return "Unmounting"
        case .failed: return "Error"
        }
    }

    var symbolName: String {
        switch self {
        case .disabled: return "pause.circle"
        case .unmounted: return "externaldrive.badge.minus"
        case .waitingForNetwork: return "network"
        case .mounting: return "arrow.triangle.2.circlepath"
        case .mounted: return "externaldrive.fill.badge.checkmark"
        case .unmounting: return "eject"
        case .failed: return "externaldrive.badge.exclamationmark"
        }
    }
}

@MainActor
final class SMBShareManager: NSObject, ObservableObject {
    @Published private(set) var shares: [ShareConfiguration] = []
    @Published private(set) var states: [UUID: ShareRuntimeState] = [:]
    @Published private(set) var logs: [AppLogEntry] = []

    private let credentialStore: CredentialStoring
    private let endpointChecker: EndpointChecking
    private let mounter: ShareMounting
    private let defaults: UserDefaults
    private let saveKey = "mountJockeyShares"
    private let retryInterval: TimeInterval = 60
    private let reachabilityTimeout: TimeInterval = 120

    private var networkMonitor: NWPathMonitor?
    private var retryTimer: Timer?
    private var operations: [UUID: Task<Void, Never>] = [:]

    init(
        credentialStore: CredentialStoring = KeychainCredentialStore.shared,
        endpointChecker: EndpointChecking = SMBEndpointChecker(),
        mounter: ShareMounting = NetFSShareMounter(),
        defaults: UserDefaults = .standard
    ) {
        self.credentialStore = credentialStore
        self.endpointChecker = endpointChecker
        self.mounter = mounter
        self.defaults = defaults
        super.init()
        loadShares()
        refreshMountStates()
        startMonitoring()
        appendLog("MountJockey started.")
    }

    deinit {
        networkMonitor?.cancel()
        retryTimer?.invalidate()
        operations.values.forEach { $0.cancel() }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func state(for share: ShareConfiguration) -> ShareRuntimeState {
        states[share.id] ?? (share.isEnabled ? .unmounted : .disabled)
    }

    func passwordExists(for share: ShareConfiguration) -> Bool {
        (try? credentialStore.password(for: share)) != nil
    }

    func saveShare(_ share: ShareConfiguration, password: String?) throws {
        var updated = shares
        if let index = updated.firstIndex(where: { $0.id == share.id }) {
            updated[index] = share
        } else {
            updated.append(share)
        }
        try ShareConfiguration.validate(updated)

        if let password, !password.isEmpty {
            try credentialStore.save(password: password, for: share)
        }

        shares = updated.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        saveShares()
        states[share.id] = share.isEnabled ? .unmounted : .disabled
        appendLog("Saved configuration for \(share.name).")

        if share.isEnabled {
            mount(share)
        }
    }

    func removeShare(_ share: ShareConfiguration, removeCredential: Bool = true) {
        operations[share.id]?.cancel()
        operations[share.id] = nil
        if removeCredential {
            try? credentialStore.deletePassword(for: share)
        }
        shares.removeAll { $0.id == share.id }
        states[share.id] = nil
        saveShares()
        appendLog("Removed \(share.name).")
    }

    func setEnabled(_ enabled: Bool, for share: ShareConfiguration) {
        guard var updated = shares.first(where: { $0.id == share.id }) else { return }
        updated.isEnabled = enabled
        try? saveShare(updated, password: nil)
        if !enabled {
            operations[share.id]?.cancel()
            operations[share.id] = nil
            states[share.id] = .disabled
        }
    }

    func mountAll() {
        refreshMountStates()
        for share in shares where share.isEnabled && state(for: share) != .mounted {
            mount(share)
        }
    }

    func mount(_ share: ShareConfiguration) {
        guard share.isEnabled, operations[share.id] == nil else { return }
        guard !MountTable.current().isMounted(
            host: share.host,
            share: share.shareName,
            at: share.normalizedMountPoint
        ) else {
            states[share.id] = .mounted
            return
        }

        states[share.id] = .waitingForNetwork
        appendLog("Waiting for SMB endpoint \(share.host):445 for \(share.name).")

        operations[share.id] = Task { [weak self] in
            guard let self else { return }
            defer { operations[share.id] = nil }

            let deadline = Date().addingTimeInterval(reachabilityTimeout)
            var reachable = false
            while !Task.isCancelled && Date() < deadline {
                if await endpointChecker.isReachable(
                    host: share.host,
                    port: 445,
                    timeout: 5
                ) {
                    reachable = true
                    break
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }

            guard !Task.isCancelled else { return }
            guard reachable else {
                states[share.id] = .failed("SMB endpoint did not become reachable within 120 seconds.")
                appendLog("Timed out waiting for \(share.host):445.", level: .warning)
                return
            }

            states[share.id] = .mounting
            appendLog("SMB endpoint is reachable; mounting \(share.name).")

            do {
                guard let password = try credentialStore.password(for: share), !password.isEmpty else {
                    throw MountJockeyError.credentialMissing
                }
                try await Task.detached(priority: .utility) {
                    try self.mounter.mount(share, password: password)
                }.value
                states[share.id] = .mounted
                appendLog("Mounted \(share.name) at \(share.normalizedMountPoint).")
            } catch {
                states[share.id] = .failed(error.localizedDescription)
                appendLog("Failed mounting \(share.name): \(error.localizedDescription)", level: .error)
            }
        }
    }

    func unmount(_ share: ShareConfiguration) {
        guard operations[share.id] == nil else { return }
        states[share.id] = .unmounting
        operations[share.id] = Task { [weak self] in
            guard let self else { return }
            defer { operations[share.id] = nil }

            do {
                try await Task.detached(priority: .utility) {
                    try self.mounter.unmount(share)
                }.value
                states[share.id] = share.isEnabled ? .unmounted : .disabled
                appendLog("Unmounted \(share.name).")
            } catch {
                states[share.id] = .failed(error.localizedDescription)
                appendLog("Failed unmounting \(share.name): \(error.localizedDescription)", level: .error)
            }
        }
    }

    func openInFinder(_ share: ShareConfiguration) {
        NSWorkspace.shared.open(URL(fileURLWithPath: share.normalizedMountPoint))
    }

    func openLog() {
        NSWorkspace.shared.open(AppLogger.shared.logURL)
    }

    func refreshMountStates() {
        let table = MountTable.current()
        for share in shares {
            if table.isMounted(
                host: share.host,
                share: share.shareName,
                at: share.normalizedMountPoint
            ) {
                states[share.id] = .mounted
            } else if operations[share.id] == nil {
                states[share.id] = share.isEnabled ? .unmounted : .disabled
            }
        }
    }

    private func loadShares() {
        guard
            let data = defaults.data(forKey: saveKey),
            let decoded = try? JSONDecoder().decode([ShareConfiguration].self, from: data),
            (try? ShareConfiguration.validate(decoded)) != nil
        else {
            shares = [.defaultShare()]
            saveShares()
            return
        }
        shares = decoded
    }

    private func saveShares() {
        guard let data = try? JSONEncoder().encode(shares) else { return }
        defaults.set(data, forKey: saveKey)
    }

    private func startMonitoring() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                self?.appendLog("Network path changed; checking configured shares.")
                self?.mountAll()
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.valmayaki.mountjockey.network"))
        networkMonitor = monitor

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(volumeDidUnmount),
            name: NSWorkspace.didUnmountNotification,
            object: nil
        )

        retryTimer = Timer.scheduledTimer(
            withTimeInterval: retryInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.mountAll()
            }
        }

        Task { @MainActor in
            mountAll()
        }
    }

    @objc private func didWake() {
        appendLog("Mac woke from sleep; checking configured shares.")
        mountAll()
    }

    @objc private func volumeDidUnmount() {
        refreshMountStates()
        mountAll()
    }

    private func appendLog(_ message: String, level: LogLevel = .info) {
        let entry = AppLogEntry(level: level, message: message)
        logs.append(entry)
        if logs.count > 200 {
            logs.removeFirst(logs.count - 200)
        }
        AppLogger.shared.write(message, level: level)
    }
}
