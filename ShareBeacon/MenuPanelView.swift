import AppKit
import SwiftUI

/// The panel the menu bar icon opens: shares grouped by host, each host with
/// the link it runs over, and the app actions in a footer.
struct MenuPanelView: View {
    @Environment(SMBShareManager.self) private var manager
    @Environment(UpdateChecker.self) private var updateChecker
    @Environment(\.openSettings) private var openSettings
    @AppStorage("selectedSettingsTab") private var selectedSettingsTab = SettingsTab.shares.rawValue
    @AppStorage("menuCollapsedHosts") private var collapsedHostsStorage = ""
    /// Settings reads this to open the editor for a new share. A link or the
    /// panel can therefore start the add flow without owning the window.
    @AppStorage("addShareRequested") private var addShareRequested = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if manager.shares.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(hostGroups, id: \.host) { group in
                            Section {
                                if !isCollapsed(group.host) {
                                    ForEach(group.shares) { share in
                                        ShareMenuRow(share: share)
                                    }
                                }
                            } header: {
                                HostHeader(
                                    host: group.host,
                                    link: group.link,
                                    traffic: manager.traffic(forHost: group.host),
                                    mounted: group.mountedCount,
                                    total: group.shares.count,
                                    collapsed: isCollapsed(group.host),
                                    toggle: { toggleCollapsed(group.host) },
                                    mountAll: { manager.mountAll(onHost: group.host) },
                                    unmountAll: { manager.unmountAll(onHost: group.host) }
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 560)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            footer
        }
        .frame(width: 380)
        .onAppear {
            manager.startPanelRefresh()
            manager.startTrafficSampling()
            Task { await updateChecker.checkIfNeeded() }
        }
        .onDisappear {
            manager.stopPanelRefresh()
            manager.stopTrafficSampling()
        }
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: summarySymbol)
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(summaryColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("ShareBeacon")
                    .font(.headline)
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if hasSharesWaitingToMount {
                Button("Mount All") { manager.mountAllEnabled() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No shares configured")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var footer: some View {
        HStack(spacing: 2) {
            FooterButton(title: "Add Share", symbol: "plus") {
                addShareRequested = true
                showSettings(tab: .shares)
            }
            FooterButton(title: "Settings", symbol: "gearshape") {
                showSettings(tab: .shares)
            }
            FooterButton(title: "Log", symbol: "list.bullet.rectangle") {
                showSettings(tab: .log)
            }
            FooterButton(title: "About", symbol: "info.circle") {
                closePanel()
                NSApp.activate(ignoringOtherApps: true)
                NSApplication.shared.orderFrontStandardAboutPanel(
                    options: [.credits: AppMetadata.aboutCredits]
                )
            }
            Spacer()
            if let update = updateChecker.availableUpdate {
                Button {
                    NSWorkspace.shared.open(update.releaseURL)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down.circle")
                        Text("Update \(update.version)")
                            .monospacedDigit()
                    }
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.orange)
                .help("ShareBeacon \(update.version) is available")
            }
            Text(AppMetadata.versionLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            FooterButton(title: "Quit", symbol: "power") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func showSettings(tab: SettingsTab) {
        selectedSettingsTab = tab.rawValue
        closePanel()
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }

    private func closePanel() {
        NSApp.keyWindow?.close()
    }

    // MARK: Summary

    private var mountedCount: Int {
        manager.shares.filter { manager.state(for: $0) == .mounted }.count
    }

    private var failedCount: Int {
        manager.shares.filter {
            if case .failed = manager.state(for: $0) { return true }
            return false
        }.count
    }

    private var unexpectedLinkCount: Int {
        manager.shares.filter(manager.isOnUnexpectedLink).count
    }

    private var unresponsiveCount: Int {
        manager.shares.filter(manager.isUnresponsive).count
    }

    private var hasSharesWaitingToMount: Bool {
        manager.shares.contains { $0.isEnabled && manager.state(for: $0) != .mounted }
    }

    private var summaryText: String {
        var parts = ["\(mountedCount) of \(manager.shares.count) mounted"]
        if failedCount > 0 { parts.append("\(failedCount) failed") }
        if unresponsiveCount > 0 { parts.append("\(unresponsiveCount) not responding") }
        if unexpectedLinkCount > 0 { parts.append("\(unexpectedLinkCount) off cable") }
        // Lines break only between items, never inside one.
        return parts
            .map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }
            .joined(separator: " · ")
    }

    private var summarySymbol: String {
        if failedCount > 0 || unexpectedLinkCount > 0 || unresponsiveCount > 0 {
            return "externaldrive.badge.exclamationmark"
        }
        if mountedCount > 0 { return "externaldrive.fill.badge.checkmark" }
        return "externaldrive.badge.wifi"
    }

    private var summaryColor: Color {
        if failedCount > 0 { return .red }
        if unexpectedLinkCount > 0 || unresponsiveCount > 0 { return .orange }
        if mountedCount > 0 { return .green }
        return .secondary
    }

    // MARK: Grouping

    private struct HostGroup {
        let host: String
        let shares: [ShareConfiguration]
        let link: NetworkLink?
        let mountedCount: Int
    }

    private var hostGroups: [HostGroup] {
        let grouped = Dictionary(grouping: manager.shares) {
            $0.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return grouped.keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { key in
                let shares = grouped[key] ?? []
                return HostGroup(
                    host: shares.first?.host ?? key,
                    shares: shares,
                    link: shares.lazy.compactMap { manager.link(for: $0) }.first,
                    mountedCount: shares.filter { manager.state(for: $0) == .mounted }.count
                )
            }
    }

    private var collapsedHosts: Set<String> {
        Set(collapsedHostsStorage.split(separator: "\n").map(String.init))
    }

    private func isCollapsed(_ host: String) -> Bool {
        collapsedHosts.contains(host.lowercased())
    }

    private func toggleCollapsed(_ host: String) {
        var hosts = collapsedHosts
        let key = host.lowercased()
        if hosts.contains(key) {
            hosts.remove(key)
        } else {
            hosts.insert(key)
        }
        collapsedHostsStorage = hosts.sorted().joined(separator: "\n")
    }
}

private struct HostHeader: View {
    let host: String
    let link: NetworkLink?
    let traffic: TrafficRate?
    let mounted: Int
    let total: Int
    let collapsed: Bool
    let toggle: () -> Void
    let mountAll: () -> Void
    let unmountAll: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                    Image(systemName: "server.rack")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(host)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("\(mounted)/\(total)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // The figure changes, the slot does not.
            Text(traffic?.label ?? "")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 96, alignment: .trailing)
                .help(traffic?.detail ?? "")

            if let link {
                LinkBadge(link: link)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 3)
        .contextMenu {
            Button("Mount all shares on \(host)", action: mountAll)
                .disabled(mounted == total)
            Button("Unmount all shares on \(host)", action: unmountAll)
                .disabled(mounted == 0)
        }
        .animation(.snappy(duration: 0.15), value: collapsed)
    }
}

/// A capsule naming the path to a host, tinted by link kind.
private struct LinkBadge: View {
    let link: NetworkLink

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: link.symbolName)
            Text(title)
                .monospacedDigit()
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.15), in: Capsule())
        .help("\(link.label) (\(link.interfaceName))")
    }

    /// The badge names the path. A wired link shows its negotiated speed
    /// instead of the word, because the cable icon already says what it is and
    /// the header needs the room. A Wi-Fi rate moves with the radio, so that
    /// one stays in the tooltip.
    private var title: String {
        switch link.kind {
        case .wired:
            return link.shortSpeed ?? "Ethernet"
        case .wifi:
            return "Wi-Fi"
        case .tunnel:
            return "VPN"
        case .other:
            return link.interfaceName
        }
    }

    private var tint: Color {
        switch link.kind {
        case .wired: return .green
        case .wifi: return .blue
        case .tunnel: return .purple
        case .other: return .secondary
        }
    }
}

private struct ShareMenuRow: View {
    @Environment(SMBShareManager.self) private var manager
    let share: ShareConfiguration
    @State private var isHovered = false

    private var state: ShareRuntimeState { manager.state(for: share) }
    private var isMounted: Bool { state == .mounted }
    private var offCable: Bool { manager.isOnUnexpectedLink(share) }
    private var notResponding: Bool { manager.isUnresponsive(share) }
    private var waitingForNetwork: Bool { isMounted && !manager.isNetworkAvailable }
    private var canMoveToCable: Bool { manager.canMoveToCable(share) }

    var body: some View {
        HStack(spacing: 8) {
            statusIcon
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(share.name)
                    .lineLimit(1)
                    .foregroundStyle(share.isEnabled ? .primary : .secondary)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(detailColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            // One slot, one piece of information, whatever the state. The
            // cable case takes the slot because it is the one state with an
            // action worth a click.
            Group {
                if isMounted, canMoveToCable {
                    Button {
                        manager.remount(share)
                    } label: {
                        Label("Cable", systemImage: "cable.connector")
                            .font(.callout.weight(.semibold))
                    }
                    .buttonStyle(.glass)
                    .controlSize(.mini)
                    .help("A cable reaches \(share.host). Remount to move this share onto it.")
                } else if isMounted, let usage = manager.usage(for: share) {
                    UsageGauge(usage: usage)
                } else {
                    Text("")
                }
            }
            .frame(width: 168, height: 20, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: primaryAction)
        .contextMenu { contextActions }
        .help(rowHelp)
    }

    private var rowHelp: String {
        var lines = ["smb://\(share.host)/\(share.shareName)"]
        if let link = manager.link(for: share) {
            lines.append("Via \(link.label) (\(link.interfaceName))")
        }
        if let usage = manager.usage(for: share) {
            lines.append(usage.detail)
        }
        lines.append(isMounted ? "Click to open in Finder" : "Click to mount")
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch state {
        case .mounted where waitingForNetwork:
            Image(systemName: "wifi.slash")
                .font(.callout)
                .foregroundStyle(.orange)
        case .mounted where notResponding:
            Image(systemName: "hourglass")
                .font(.callout)
                .foregroundStyle(.orange)
        case .mounted:
            Image(systemName: offCable ? "wifi.exclamationmark" : "circle.fill")
                .font(offCable ? .callout : .system(size: 7))
                .foregroundStyle(offCable ? .orange : .green)
        case .mounting, .unmounting, .waitingForNetwork:
            ProgressView()
                .controlSize(.mini)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
        case .disabled:
            Image(systemName: "pause.circle")
                .font(.callout)
                .foregroundStyle(.tertiary)
        case .unmounted:
            Image(systemName: "circle")
                .font(.system(size: 7))
                .foregroundStyle(.tertiary)
        }
    }

    /// Always present, so every row has the same height and nothing jumps when
    /// a share changes state.
    private var detail: String {
        switch state {
        case .failed(let message): return message
        case .mounted:
            if waitingForNetwork { return "Waiting for network" }
            if notResponding { return "Not responding" }
            if canMoveToCable { return "Cable available" }
            return offCable ? "Expected a wired link" : "Mounted"
        case .unmounted: return "Not mounted"
        case .disabled: return "Disabled"
        case .mounting, .unmounting, .waitingForNetwork: return state.label
        }
    }

    private var detailColor: Color {
        switch state {
        case .failed: return .red
        case .mounted: return waitingForNetwork || notResponding || canMoveToCable || offCable ? .orange : .secondary
        default: return .secondary
        }
    }

    @ViewBuilder
    private var contextActions: some View {
        Button("Mount Now") { manager.mount(share, explicit: true) }
            .disabled(isMounted || !share.isEnabled)
        Button("Unmount") { manager.unmount(share) }
            .disabled(!isMounted)
        Button(canMoveToCable ? "Remount onto Cable" : "Remount") { manager.remount(share) }
            .disabled(!isMounted)
        Button("Open in Finder") { manager.openInFinder(share) }
            .disabled(!isMounted)
        Button("Add to Finder Favorites") { manager.restoreFinderFavorite(share) }
            .disabled(!isMounted)
        Divider()
        Button(share.isEnabled ? "Disable Share" : "Enable Share") {
            manager.setEnabled(!share.isEnabled, for: share)
        }
    }

    private func primaryAction() {
        if isMounted {
            manager.openInFinder(share)
        } else if share.isEnabled {
            manager.mount(share, explicit: true)
        }
    }
}

/// Free space as a slim bar and a short figure; the bar warms up as the disk fills.
private struct UsageGauge: View {
    let usage: VolumeUsage

    var body: some View {
        HStack(spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(tint.gradient)
                        .frame(width: max(3, proxy.size.width * usage.usedFraction))
                }
            }
            .frame(width: 44, height: 5)
            .padding(.trailing, 2)
            // Fixed columns keep free and total figures aligned from row to row.
            Text(usage.shortFree)
                .foregroundStyle(usage.usedFraction > 0.98 ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                .frame(width: 48, alignment: .trailing)
            Text("of")
                .foregroundStyle(.tertiary)
            Text(usage.shortTotal)
                .foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .leading)
        }
        .font(.callout.monospacedDigit())
        .lineLimit(1)
        .fixedSize()
        .help(usage.detail)
    }

    private var tint: Color {
        switch usage.usedFraction {
        case 0.98...: return .red
        case 0.9...: return .orange
        default: return .accentColor
        }
    }
}

private struct FooterButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body)
                .frame(width: 30, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { isHovered = $0 }
        .help(title)
    }
}
