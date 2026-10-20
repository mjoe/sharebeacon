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
    private(set) var restoresFavoritesByDefault = true
    /// The interface each mounted share's SMB session actually uses.
    private(set) var links: [UUID: NetworkLink] = [:]
    /// The interface a new connection to each share's host would take.
    private(set) var preferredLinks: [UUID: NetworkLink] = [:]
    private(set) var usages: [UUID: VolumeUsage] = [:]
    private(set) var unresponsive: Set<UUID> = []
    /// TCP connect time to port 445, keyed by `hostKey`.
    private(set) var latencies: [String: Duration] = [:]
    /// Session traffic, keyed by `hostKey`, while the menu panel samples it.
    private(set) var traffic: [String: TrafficRate] = [:]

    @ObservationIgnored private let credentialStore: CredentialStoring
    @ObservationIgnored private let endpointChecker: EndpointChecking
    @ObservationIgnored private let mounter: ShareMounting
    @ObservationIgnored private let finderSidebarRepairer: FinderSidebarRepairing
    @ObservationIgnored private let linkResolver: NetworkLinkResolving
    @ObservationIgnored private let defaults: UserDefaults
    private let saveKey = "shareBeaconShares"
    private let favoriteKey = "shareBeaconRestoresFavorites"
    private let retryInterval: TimeInterval = 60
    private let reachabilityTimeout: TimeInterval = 120
    private let wakeGraceInterval: TimeInterval = 5

    @ObservationIgnored private var networkMonitor: NWPathMonitor?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var operations: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var adoptedMountPoints: [UUID: String] = [:]
    @ObservationIgnored private var manuallyUnmounted: Set<UUID> = []
    @ObservationIgnored private var isSleeping = false
    @ObservationIgnored private let operationRunner = MountOperationRunner()
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var statusRefreshPending = false
    @ObservationIgnored private var unresponsiveStreaks: [UUID: Int] = [:]
    @ObservationIgnored private var trafficTask: Task<Void, Never>?
    @ObservationIgnored private var trafficSamplers = 0
    private let unresponsiveProbesBeforeRemount = 2

    init(
        credentialStore: CredentialStoring = KeychainCredentialStore.shared,
        endpointChecker: EndpointChecking = SMBEndpointChecker(),
        mounter: ShareMounting = NetFSShareMounter(),
        finderSidebarRepairer: FinderSidebarRepairing = FinderSidebarRepairer(),
        linkResolver: NetworkLinkResolving = SystemNetworkLinkResolver(),
        defaults: UserDefaults = .standard
    ) {
        self.credentialStore = credentialStore
        self.endpointChecker = endpointChecker
        self.mounter = mounter
        self.finderSidebarRepairer = finderSidebarRepairer
        self.linkResolver = linkResolver
        self.defaults = defaults
        super.init()
        restoresFavoritesByDefault = defaults.object(forKey: favoriteKey) as? Bool ?? true
        loadShares()
        refreshMountStates()
        startMonitoring()
        appendLog("ShareBeacon started.")
    }

    deinit {
        networkMonitor?.cancel()
        retryTask?.cancel()
        wakeTask?.cancel()
        statusTask?.cancel()
        trafficTask?.cancel()
        operations.values.forEach { $0.cancel() }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func state(for share: ShareConfiguration) -> ShareRuntimeState {
        states[share.id] ?? (share.isEnabled ? .unmounted : .disabled)
    }

    /// The interface a mounted share is routed through, when it is known.
    func link(for share: ShareConfiguration) -> NetworkLink? {
        state(for: share) == .mounted ? links[share.id] : nil
    }

    /// Whether a cable reaches the share's host while its session still runs
    /// over another link, so a remount would move it to the cable.
    func canMoveToCable(_ share: ShareConfiguration) -> Bool {
        guard let preferred = state(for: share) == .mounted ? preferredLinks[share.id] : nil,
              let current = link(for: share)
        else { return false }
        return preferred.kind == .wired && current.kind != .wired
    }

    func usage(for share: ShareConfiguration) -> VolumeUsage? {
        state(for: share) == .mounted ? usages[share.id] : nil
    }

    func isUnresponsive(_ share: ShareConfiguration) -> Bool {
        state(for: share) == .mounted && unresponsive.contains(share.id)
    }

    func latency(forHost host: String) -> Duration? {
        latencies[Self.hostKey(host)]
    }

    func traffic(forHost host: String) -> TrafficRate? {
        traffic[Self.hostKey(host)]
    }

    static func hostKey(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Whether a mounted share runs over a link other than the one it expects.
    func isOnUnexpectedLink(_ share: ShareConfiguration) -> Bool {
        !share.linkExpectation.isSatisfied(by: link(for: share))
    }

    func passwordExists(for share: ShareConfiguration) -> Bool {
        credentialStore.hasPassword(for: share)
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
            ($0.isEnabled && !share.isEnabled) ||
            ($0.autoMount && !share.autoMount)
        } ?? false

        if needsReconciliation,
           let existing,
           MountTable.current().mountPoint(host: existing.host, share: existing.shareName) != nil {
            unmount(existing, thenMount: share.isEnabled && share.autoMount ? share : nil)
        } else if share.isEnabled && share.autoMount {
            mount(share)
        }
    }

    func removeShare(_ share: ShareConfiguration, removeCredential: Bool = true) {
        operations[share.id]?.cancel()
        operations[share.id] = nil
        adoptedMountPoints[share.id] = nil
        if removeCredential,
           !shares.contains(where: {
               $0.id != share.id && $0.credentialAccount == share.credentialAccount
           }) {
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

    func setAutoMount(_ autoMount: Bool, for share: ShareConfiguration) {
        guard var updated = shares.first(where: { $0.id == share.id }) else { return }
        updated.autoMount = autoMount
        try? saveShare(updated, password: nil)
    }

    func sharedCredentials(forHost host: String) -> [SharedCredential] {
        credentialStore.sharedCredentials(forHost: host)
    }

    func updateSharedCredential(_ credential: SharedCredential, password: String) throws {
        try credentialStore.saveSharedCredential(credential, password: password)
        appendLog("Updated shared credential for \(credential.username)@\(credential.host).")
    }

    func deleteSharedCredential(_ credential: SharedCredential) throws {
        try credentialStore.deleteSharedCredential(credential)
        appendLog("Deleted shared credential for \(credential.username)@\(credential.host).")
    }

    func mountAutoMountingShares() {
        refreshMountStates()
        for share in sharesWaitingForAutoMount {
            mount(share)
        }
        refreshStatus()
    }

    /// Looks at every mounted share off the main actor: the link its session
    /// uses, the link a new connection would take, its free space and whether
    /// it still answers. A share that stops answering for two probes in a row
    /// is remounted when it mounts automatically.
    func refreshStatus() {
        guard statusTask == nil else {
            statusRefreshPending = true
            return
        }
        let targets = shares
            .filter { state(for: $0) == .mounted }
            .map { (id: $0.id, host: $0.host, path: mountPath(for: $0)) }
        let hosts = Set(targets.map { Self.hostKey($0.host) })
        let resolver = linkResolver
        let checker = endpointChecker
        statusTask = Task { [weak self] in
            let report = await Task.detached {
                let sessions = SMBSessionReader.read()
                let byPath = Dictionary(
                    sessions.map { (URL(fileURLWithPath: $0.mountPath).standardizedFileURL.path, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                var report: [UUID: (link: NetworkLink?, preferred: NetworkLink?, probe: VolumeProbe)] = [:]
                for target in targets {
                    let preferred = resolver.link(toHost: target.host)
                    let channel = byPath[target.path]?.activeChannel
                    let link = channel?.clientInterface.flatMap(resolver.link(forInterface:))
                        ?? channel.flatMap { resolver.link(toHost: $0.serverAddress) }
                        ?? preferred
                    report[target.id] = (link, preferred, VolumeProber.probe(path: target.path))
                }
                return report
            }.value

            var latencies: [String: Duration] = [:]
            for host in hosts {
                let start = ContinuousClock.now
                if await checker.isReachable(host: host, port: 445, timeout: 2) {
                    latencies[host] = ContinuousClock.now - start
                }
            }

            guard let self else { return }
            statusTask = nil
            apply(report, latencies: latencies)
            if statusRefreshPending {
                statusRefreshPending = false
                refreshStatus()
            }
        }
    }

    private func apply(
        _ report: [UUID: (link: NetworkLink?, preferred: NetworkLink?, probe: VolumeProbe)],
        latencies: [String: Duration]
    ) {
        var stale: [ShareConfiguration] = []
        for share in shares {
            guard let entry = report[share.id] else { continue }
            let old = links[share.id]
            if let new = entry.link, old?.interfaceName != new.interfaceName {
                if !share.linkExpectation.isSatisfied(by: new) {
                    appendLog("\(share.name) is routed over \(new.label) (\(new.interfaceName)), not a wired link.", level: .warning)
                } else if old != nil {
                    appendLog("\(share.name) is now routed over \(new.label) (\(new.interfaceName)).")
                }
            }
            let couldMove = canMoveToCable(share)
            links[share.id] = entry.link
            preferredLinks[share.id] = entry.preferred
            if !couldMove && canMoveToCable(share) {
                appendLog("A cable reaches \(share.host), but \(share.name) still runs over \(entry.link?.label ?? "another link"); remount to move it.")
            }

            switch entry.probe {
            case .usage(let usage):
                usages[share.id] = usage
                if unresponsive.remove(share.id) != nil {
                    appendLog("\(share.name) is responding again.")
                }
                unresponsiveStreaks[share.id] = nil
            case .unresponsive:
                if unresponsive.insert(share.id).inserted {
                    appendLog("\(share.name) is not responding.", level: .warning)
                }
                let streak = (unresponsiveStreaks[share.id] ?? 0) + 1
                unresponsiveStreaks[share.id] = streak
                if streak == unresponsiveProbesBeforeRemount && share.isEnabled && share.autoMount {
                    stale.append(share)
                }
            case .unavailable:
                usages[share.id] = nil
            }
        }
        self.latencies = latencies
        for share in stale {
            appendLog("\(share.name) stopped responding; remounting.", level: .warning)
            remount(share)
        }
    }

    /// Unmounts a share and mounts it again, which also moves its session to
    /// whatever link the routing table prefers now.
    func remount(_ share: ShareConfiguration) {
        guard state(for: share) == .mounted else {
            mount(share, explicit: true)
            return
        }
        manuallyUnmounted.remove(share.id)
        unresponsive.remove(share.id)
        unresponsiveStreaks[share.id] = nil
        appendLog("Remounting \(share.name).")
        unmount(share, thenMount: share, evenWithoutAutoMount: true)
    }

    func mountAll(onHost host: String) {
        for share in shares(onHost: host) where share.isEnabled && state(for: share) != .mounted {
            mount(share, explicit: true)
        }
    }

    func unmountAll(onHost host: String) {
        for share in shares(onHost: host) where state(for: share) == .mounted {
            unmount(share)
        }
    }

    private func shares(onHost host: String) -> [ShareConfiguration] {
        let key = Self.hostKey(host)
        return shares.filter { Self.hostKey($0.host) == key }
    }

    // MARK: Traffic

    /// Samples session traffic every two seconds while at least one caller,
    /// such as the open menu panel, asks for it.
    func startTrafficSampling() {
        trafficSamplers += 1
        guard trafficTask == nil else { return }
        trafficTask = Task { [weak self] in
            var previous: (sessions: [String: SMBSession], at: ContinuousClock.Instant)?
            while !Task.isCancelled {
                let sessions = await Task.detached { SMBSessionReader.read(timeout: 3) }.value
                let now = ContinuousClock.now
                guard let self, !Task.isCancelled else { return }
                let byPath = Dictionary(
                    sessions.map { (URL(fileURLWithPath: $0.mountPath).standardizedFileURL.path, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                if let previous {
                    let seconds = Double((now - previous.at).components.seconds)
                        + Double((now - previous.at).components.attoseconds) / 1e18
                    var rates: [String: TrafficRate] = [:]
                    for share in shares where state(for: share) == .mounted {
                        let path = mountPath(for: share)
                        guard let old = previous.sessions[path], let new = byPath[path] else { continue }
                        // Shares of one server share its session counters, so one sample per host is enough.
                        rates[Self.hostKey(share.host)] = TrafficRate(from: old, to: new, seconds: seconds)
                    }
                    traffic = rates
                }
                previous = (byPath, now)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopTrafficSampling() {
        trafficSamplers = max(0, trafficSamplers - 1)
        guard trafficSamplers == 0 else { return }
        trafficTask?.cancel()
        trafficTask = nil
        traffic = [:]
    }

    // MARK: Commands

    /// Runs a `sharebeacon://` command. Settings and Log are left to the caller,
    /// which owns the windows.
    func perform(_ command: ShareBeaconCommand) {
        func matching(_ target: ShareBeaconCommand.Target) -> [ShareConfiguration] {
            shares.filter { ShareBeaconCommand.matches(target, $0) }
        }
        switch command {
        case .mount(let target):
            matching(target).filter { $0.isEnabled }.forEach { mount($0, explicit: true) }
        case .unmount(let target):
            matching(target).filter { state(for: $0) == .mounted }.forEach { unmount($0) }
        case .remount(let target):
            matching(target).filter { $0.isEnabled }.forEach { remount($0) }
        case .open(let name):
            matching(.share(name)).filter { state(for: $0) == .mounted }.forEach { openInFinder($0) }
        case .settings, .log:
            break
        }
    }

    func mountAllEnabled() {
        refreshMountStates()
        for share in shares where share.isEnabled && state(for: share) != .mounted {
            mount(share)
        }
    }

    var sharesWaitingForAutoMount: [ShareConfiguration] {
        shares.filter {
            $0.isEnabled
                && $0.autoMount
                && !manuallyUnmounted.contains($0.id)
                && state(for: $0) != .mounted
        }
    }

    func mountPath(for share: ShareConfiguration) -> String {
        adoptedMountPoints[share.id] ?? share.normalizedMountPoint
    }

    func mount(_ share: ShareConfiguration, explicit: Bool = false) {
        manuallyUnmounted.remove(share.id)
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
                if restoreFavoriteIfEnabled(for: share, at: existingPoint) {
                    appendLog("Restored Finder favorite for \(share.name).")
                }
            }
            return
        }

        adoptedMountPoints[share.id] = nil
        if explicit {
            states[share.id] = .mounting
            appendLog("Mounting \(share.name) on demand.")
        } else {
            states[share.id] = .waitingForNetwork
            appendLog("Waiting for SMB endpoint \(share.host):445 for \(share.name).")
        }

        operations[share.id] = Task { [weak self] in
            guard let self else { return }
            defer { operations[share.id] = nil }

            if explicit {
                guard await endpointChecker.isReachable(
                    host: share.host,
                    port: 445,
                    timeout: 3
                ) else {
                    states[share.id] = .failed("SMB endpoint \(share.host) is not reachable.")
                    appendLog(
                        "\(share.name): \(share.host):445 is not reachable.",
                        level: .warning
                    )
                    return
                }
            } else {
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
                    try? await Task.sleep(for: .seconds(5))
                }

                guard !Task.isCancelled else { return }
                guard reachable else {
                    states[share.id] = .failed("SMB endpoint did not become reachable within 120 seconds.")
                    appendLog("Timed out waiting for \(share.host):445.", level: .warning)
                    return
                }
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
                refreshStatus()
                if restoreFavoriteIfEnabled(for: share, at: nil) {
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
                    if restoreFavoriteIfEnabled(
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
        manuallyUnmounted.insert(share.id)
        unmount(share, thenMount: nil)
    }

    private func unmount(
        _ share: ShareConfiguration,
        thenMount replacement: ShareConfiguration?,
        evenWithoutAutoMount: Bool = false
    ) {
        guard operations[share.id] == nil else { return }
        states[share.id] = .unmounting
        operations[share.id] = Task { [weak self] in
            guard let self else { return }
            defer {
                operations[share.id] = nil
                if let replacement,
                   shares.contains(where: { $0.id == replacement.id }),
                   replacement.isEnabled && (replacement.autoMount || evenWithoutAutoMount) {
                    mount(replacement, explicit: evenWithoutAutoMount)
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
        let path = mountPath(for: share)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
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
            shares = []
            saveShares()
            return
        }
        shares = decoded
    }

    private func saveShares() {
        guard let data = try? JSONEncoder().encode(shares) else { return }
        defaults.set(data, forKey: saveKey)
    }

    func setRestoresFavoritesByDefault(_ enabled: Bool) {
        restoresFavoritesByDefault = enabled
        defaults.set(enabled, forKey: favoriteKey)
    }

    /// Restores the Finder favorite only when the share asks for it. The manual
    /// Add to Finder Favorites action bypasses this and always writes.
    private func restoreFavoriteIfEnabled(for share: ShareConfiguration, at mountPoint: String?) -> Bool {
        guard share.restoresFavorite(generalDefault: restoresFavoritesByDefault) else { return false }
        return finderSidebarRepairer.restoreFavorite(for: share, at: mountPoint)
    }

    private func startMonitoring() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                guard let self, !self.isSleeping else { return }
                self.appendLog("Network path changed; checking configured shares.")
                self.mountAutoMountingShares()
            }
        }
        monitor.start(queue: DispatchQueue(label: "org.mjoe.sharebeacon.network"))
        networkMonitor = monitor

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(didSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
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

        startRetryTask()

        Task { @MainActor in
            mountAutoMountingShares()
        }
    }

    private func startRetryTask() {
        retryTask?.cancel()
        let retryInterval = self.retryInterval
        retryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(retryInterval))
                guard !Task.isCancelled else { return }
                guard let self, !self.isSleeping else { continue }
                self.mountAutoMountingShares()
            }
        }
    }

    @objc private func didSleep() {
        guard !isSleeping else { return }
        isSleeping = true
        retryTask?.cancel()
        wakeTask?.cancel()
        operations.values.forEach { $0.cancel() }
        operations.removeAll()
        appendLog("Mac is sleeping; pausing share monitoring.")
    }

    @objc private func didWake() {
        isSleeping = false
        appendLog("Mac woke from sleep; resuming share monitoring.")
        startRetryTask()
        wakeTask?.cancel()
        wakeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.wakeGraceInterval ?? 5))
            guard !Task.isCancelled else { return }
            guard let self, !self.isSleeping else { return }
            self.appendLog("Network grace period elapsed; reconnecting shares.")
            self.mountAutoMountingShares()
        }
    }

    @objc private func volumeDidUnmount() {
        guard !isSleeping else { return }
        refreshMountStates()
        mountAutoMountingShares()
    }

    private func appendLog(_ message: String, level: LogLevel = .info) {
        AppLogger.shared.record(message, level: level)
    }
}
