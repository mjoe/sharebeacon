import AppKit
import Foundation
import Network
import Observation

private actor MountOperationRunner {
    func mount(_ mounter: ShareMounting, share: ShareConfiguration, password: String) throws {
        try mounter.mount(share, password: password)
    }

    func unmount(_ mounter: ShareMounting, share: ShareConfiguration, at mountPoint: String) throws {
        try mounter.unmount(share, at: mountPoint)
    }
}

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
@Observable
final class SMBShareManager: NSObject {
    private(set) var shares: [ShareConfiguration] = []
    private(set) var states: [UUID: ShareRuntimeState] = [:]

    @ObservationIgnored private let credentialStore: CredentialStoring
    @ObservationIgnored private let endpointChecker: EndpointChecking
    @ObservationIgnored private let mounter: ShareMounting
    @ObservationIgnored private let finderSidebarRepairer: FinderSidebarRepairing
    @ObservationIgnored private let defaults: UserDefaults
    private let saveKey = "shareBeaconShares"
    private let retryInterval: TimeInterval = 60
    private let reachabilityTimeout: TimeInterval = 120

    @ObservationIgnored private var networkMonitor: NWPathMonitor?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var operations: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var adoptedMountPoints: [UUID: String] = [:]
    @ObservationIgnored private let operationRunner = MountOperationRunner()

    init(
        credentialStore: CredentialStoring = KeychainCredentialStore.shared,
        endpointChecker: EndpointChecking = SMBEndpointChecker(),
        mounter: ShareMounting = NetFSShareMounter(),
        finderSidebarRepairer: FinderSidebarRepairing = FinderSidebarRepairer(),
        defaults: UserDefaults = .standard
    ) {
        self.credentialStore = credentialStore
        self.endpointChecker = endpointChecker
        self.mounter = mounter
        self.finderSidebarRepairer = finderSidebarRepairer
        self.defaults = defaults
        super.init()
        loadShares()
        refreshMountStates()
        startMonitoring()
        appendLog("ShareBeacon started.")
    }

    deinit {
        networkMonitor?.cancel()
        retryTask?.cancel()
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
        let existing = shares.first { $0.id == share.id }
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

        let needsReconciliation = existing.map {
            $0.mountIdentity != share.mountIdentity ||
            (password?.isEmpty == false) ||
            ($0.isEnabled && !share.isEnabled)
        } ?? false

        if needsReconciliation,
           let existing,
           MountTable.current().mountPoint(host: existing.host, share: existing.shareName) != nil {
            unmount(existing, thenMount: share.isEnabled ? share : nil)
        } else if share.isEnabled {
            mount(share)
        }
    }

    func removeShare(_ share: ShareConfiguration, removeCredential: Bool = true) {
        operations[share.id]?.cancel()
        operations[share.id] = nil
        adoptedMountPoints[share.id] = nil
        if removeCredential {
            try? credentialStore.deletePassword(for: share)
        }
        if MountTable.current().mountPoint(host: share.host, share: share.shareName) != nil {
            unmount(share)
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
    }

    func mountAll() {
        refreshMountStates()
        for share in shares where share.isEnabled && state(for: share) != .mounted {
            mount(share)
        }
    }

    func mount(_ share: ShareConfiguration) {
        guard share.isEnabled, operations[share.id] == nil else { return }

        let table = MountTable.current()
        if let existingPoint = table.mountPoint(host: share.host, share: share.shareName) {
            let configuredPoint = share.normalizedMountPoint
            if existingPoint == configuredPoint {
                adoptedMountPoints[share.id] = nil
                states[share.id] = .mounted
            } else {
                adoptedMountPoints[share.id] = existingPoint
                states[share.id] = .mounted
                appendLog(
                    "\(share.name) is already mounted at \(existingPoint); using the existing mount.",
                    level: .warning
                )
                if finderSidebarRepairer.restoreFavorite(for: share, at: existingPoint) {
                    appendLog("Restored Finder favorite for \(share.name).")
                }
            }
            return
        }

        adoptedMountPoints[share.id] = nil
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
                    throw ShareBeaconError.credentialMissing
                }
                try await operationRunner.mount(mounter, share: share, password: password)
                states[share.id] = .mounted
                appendLog("Mounted \(share.name) at \(share.normalizedMountPoint).")
                if finderSidebarRepairer.restoreFavorite(for: share, at: nil) {
                    appendLog("Restored Finder favorite for \(share.name).")
                }
            } catch {
                if let existingPoint = MountTable.current().mountPoint(forShareNamed: share.shareName) {
                    let configuredPoint = share.normalizedMountPoint
                    adoptedMountPoints[share.id] = existingPoint == configuredPoint ? nil : existingPoint
                    states[share.id] = .mounted
                    appendLog(
                        "\(share.name) is already mounted at \(existingPoint); using the existing mount.",
                        level: .warning
                    )
                    if finderSidebarRepairer.restoreFavorite(
                        for: share,
                        at: existingPoint == configuredPoint ? nil : existingPoint
                    ) {
                        appendLog("Restored Finder favorite for \(share.name).")
                    }
                } else {
                    states[share.id] = .failed(error.localizedDescription)
                    appendLog("Failed mounting \(share.name): \(error.localizedDescription)", level: .error)
                }
            }
        }
    }

    func unmount(_ share: ShareConfiguration) {
        unmount(share, thenMount: nil)
    }

    private func unmount(_ share: ShareConfiguration, thenMount replacement: ShareConfiguration?) {
        guard operations[share.id] == nil else { return }
        states[share.id] = .unmounting
        operations[share.id] = Task { [weak self] in
            guard let self else { return }
            defer {
                operations[share.id] = nil
                if let replacement,
                   shares.contains(where: { $0.id == replacement.id }),
                   replacement.isEnabled {
                    mount(replacement)
                }
            }

            do {
                try await operationRunner.unmount(mounter, share: share, at: adoptedMountPoints[share.id] ?? share.normalizedMountPoint)
                adoptedMountPoints[share.id] = nil
                if let current = shares.first(where: { $0.id == share.id }) {
                    states[share.id] = current.isEnabled ? .unmounted : .disabled
                } else {
                    states[share.id] = nil
                }
                appendLog("Unmounted \(share.name).")
            } catch {
                states[share.id] = .failed(error.localizedDescription)
                appendLog("Failed unmounting \(share.name): \(error.localizedDescription)", level: .error)
            }
        }
    }

    func openInFinder(_ share: ShareConfiguration) {
        let path = adoptedMountPoints[share.id] ?? share.normalizedMountPoint
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func openLog() {
        NSWorkspace.shared.open(AppLogger.shared.logURL)
    }

    func restoreFinderFavorite(_ share: ShareConfiguration) {
        guard state(for: share) == .mounted else { return }
        if finderSidebarRepairer.restoreFavorite(for: share, at: adoptedMountPoints[share.id]) {
            appendLog("Restored Finder favorite for \(share.name).")
        }
    }

    func refreshMountStates() {
        let table = MountTable.current()
        for share in shares {
            if let existingPoint = table.mountPoint(host: share.host, share: share.shareName) {
                adoptedMountPoints[share.id] =
                    existingPoint == share.normalizedMountPoint ? nil : existingPoint
                states[share.id] = .mounted
            } else if operations[share.id] == nil {
                adoptedMountPoints[share.id] = nil
                if case .failed = states[share.id] {
                    continue
                }
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
        monitor.start(queue: DispatchQueue(label: "com.mjoe.sharebeacon.network"))
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

        retryTask?.cancel()
        let retryInterval = self.retryInterval
        retryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(retryInterval))
                guard !Task.isCancelled else { return }
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
        AppLogger.shared.record(message, level: level)
    }
}
