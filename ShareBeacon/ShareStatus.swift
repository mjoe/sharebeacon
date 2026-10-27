import Darwin
import Foundation
import Synchronization

// MARK: - SMB sessions

/// One mounted SMB session as `smbutil multichannel` reports it.
struct SMBSession: Equatable, Sendable {
    struct Channel: Equatable, Sendable {
        /// The client interface, or nil when the session runs without multichannel.
        let clientInterface: String?
        let serverAddress: String
        let isActive: Bool
    }

    let mountPath: String
    let receivedBytes: UInt64
    let sentBytes: UInt64
    let channels: [Channel]

    /// The channel carrying traffic: the first active one, else the first one.
    var activeChannel: Channel? {
        channels.first(where: \.isActive) ?? channels.first
    }

    /// Parses the output of `smbutil multichannel -a`.
    static func parse(_ output: String) -> [SMBSession] {
        var sessions: [SMBSession] = []
        var path: String?
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var channels: [Channel] = []

        func flush() {
            if let path {
                sessions.append(SMBSession(
                    mountPath: path,
                    receivedBytes: received,
                    sentBytes: sent,
                    channels: channels
                ))
            }
            path = nil
            received = 0
            sent = 0
            channels = []
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Session: ") {
                flush()
                path = String(line.dropFirst("Session: ".count))
            } else if line.hasPrefix("Total RX Bytes:") {
                received = Self.leadingNumber(after: "Total RX Bytes:", in: line)
            } else if line.hasPrefix("Total TX Bytes:") {
                sent = Self.leadingNumber(after: "Total TX Bytes:", in: line)
            } else if path != nil, let channel = Self.channel(from: line) {
                channels.append(channel)
            }
        }
        flush()
        return sessions
    }

    private static func leadingNumber(after prefix: String, in line: String) -> UInt64 {
        let rest = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return UInt64(rest.prefix { $0.isNumber }) ?? 0
    }

    /// A channel row looks like
    /// `M 184  en8 (Ethernet) 19   8 (RSS_0) [session active ]  192.168.1.105  445  2.5 Gb`
    /// or, without multichannel, `M 140  N/A  N/A [session active ]  192.168.2.49  445  N/A`.
    private static func channel(from line: String) -> Channel? {
        guard let open = line.firstIndex(of: "["),
              let close = line[open...].firstIndex(of: "]")
        else { return nil }
        let head = line[..<open].split(separator: " ")
        let state = line[line.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        let tail = line[line.index(after: close)...].split(separator: " ")
        // A leading flag such as M marks the main channel; the id follows it.
        guard let idIndex = head.firstIndex(where: { $0.allSatisfy(\.isNumber) }),
              idIndex + 1 < head.count,
              let address = tail.first, tail.count >= 2, tail[1] == "445"
        else { return nil }
        let client = String(head[idIndex + 1])
        return Channel(
            clientInterface: client == "N/A" ? nil : client,
            serverAddress: String(address),
            isActive: state.hasSuffix("active")
        )
    }
}

/// Runs `smbutil multichannel -a` with a deadline, because a hung share can
/// stall it like any other file system call.
enum SMBSessionReader {
    /// Returns no sessions when smbutil fails or misses the deadline.
    static func read(
        timeout: TimeInterval = 5,
        executable: String = "/usr/bin/smbutil",
        arguments: [String] = ["multichannel", "-a"]
    ) -> [SMBSession] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        // Without closing the parent's copy of the write end, the read below
        // never sees end of file once the child exits.
        try? pipe.fileHandleForWriting.close()

        let output = Mutex(Data())
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            output.withLock { $0 = data }
            finished.signal()
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            stop(process)
            _ = finished.wait(timeout: .now() + 2)
            return []
        }
        process.waitUntilExit()
        return SMBSession.parse(String(decoding: output.withLock { $0 }, as: UTF8.self))
    }

    /// Ends a reader that missed its deadline. A share stuck in the kernel can
    /// hold smbutil past SIGTERM, and a surviving child would keep the pipe
    /// open and its reading thread blocked.
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        guard !waitForExit(process, timeout: 1) else { return }
        kill(process.processIdentifier, SIGKILL)
        _ = waitForExit(process, timeout: 2)
    }

    private static func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success
    }
}

// MARK: - Volume usage

struct VolumeUsage: Equatable, Sendable {
    let totalBytes: UInt64
    let freeBytes: UInt64

    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(totalBytes - min(freeBytes, totalBytes)) / Double(totalBytes)
    }

    /// Free space in a few characters, such as 3.2T or 640G.
    var shortFree: String {
        ByteFormatting.short(freeBytes)
    }

    var shortTotal: String {
        ByteFormatting.short(totalBytes)
    }

    var detail: String {
        "\(ByteFormatting.short(freeBytes)) free of \(ByteFormatting.short(totalBytes))"
    }
}

/// What a probe of a mounted share found.
enum VolumeProbe: Equatable, Sendable {
    case usage(VolumeUsage)
    /// The file system did not answer before the deadline.
    case unresponsive
    /// An earlier probe of the same share is still running, so this one made
    /// no statement either way.
    case busy
    case unavailable
}

enum VolumeProber {
    /// Asks the file system for its size on a separate thread and gives up
    /// after `timeout`. A probe that is still stuck is not started again, so
    /// a hung share holds at most one thread. A later probe of that share
    /// still counts as a miss, because the file system is still not answering.
    static func probe(path: String, timeout: TimeInterval = 4) -> VolumeProbe {
        let claimed = inFlight.withLock { $0.insert(path).inserted }
        guard claimed else {
            return stuck.withLock { $0.contains(path) } ? .unresponsive : .busy
        }

        let result = Mutex<VolumeProbe?>(nil)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            var info = statfs()
            let probe: VolumeProbe = statfs(path, &info) == 0
                ? .usage(VolumeUsage(
                    totalBytes: UInt64(info.f_blocks) * UInt64(info.f_bsize),
                    freeBytes: UInt64(info.f_bavail) * UInt64(info.f_bsize)
                ))
                : .unavailable
            result.withLock { $0 = probe }
            inFlight.withLock { _ = $0.remove(path) }
            stuck.withLock { _ = $0.remove(path) }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            stuck.withLock { _ = $0.insert(path) }
            return .unresponsive
        }
        return result.withLock { $0 } ?? .unavailable
    }

    private static let inFlight = Mutex(Set<String>())
    /// Paths whose running probe has already missed its deadline.
    private static let stuck = Mutex(Set<String>())
}

/// The rule that turns consecutive misses into a repair. Kept apart from the
/// manager so the decision can be tested without a mount.
struct RepairPolicy: Equatable, Sendable {
    /// Three misses in a row. One slow answer is not a hang, and a repair
    /// costs a reconnect, so the threshold stays above one.
    static let defaultMissesBeforeRepair = 3

    let missesBeforeRepair: Int

    init(missesBeforeRepair: Int = RepairPolicy.defaultMissesBeforeRepair) {
        self.missesBeforeRepair = missesBeforeRepair
    }

    /// A probe that found the volume busy says nothing about its health, so it
    /// leaves the streak alone. A stuck probe counts, because the file system
    /// still did not answer.
    func misses(after probe: VolumeProbe, current: Int) -> Int {
        switch probe {
        case .unresponsive:
            return current + 1
        case .busy, .unavailable:
            return current
        case .usage:
            return 0
        }
    }

    /// Only shares that mount themselves are repaired. A manual mount belongs
    /// to the user, who may be in the middle of a copy.
    func shouldRepair(misses: Int, isEnabled: Bool, autoMount: Bool) -> Bool {
        isEnabled && autoMount && misses >= missesBeforeRepair
    }
}

/// What a probe changed about a share's health.
struct ShareHealthChange: Equatable, Sendable {
    /// The share just stopped answering.
    var becameUnresponsive = false
    /// The share answered again after being marked unresponsive.
    var recovered = false
    /// This miss is the one that should start a repair.
    var shouldRepair = false
}

/// Tracks which shares stopped answering and how many probes missed in a row.
struct ShareHealth: Equatable, Sendable {
    let policy: RepairPolicy
    private var unresponsiveShares: Set<UUID> = []
    private var missStreaks: [UUID: Int] = [:]

    init(policy: RepairPolicy = RepairPolicy()) {
        self.policy = policy
    }

    func isUnresponsive(_ id: UUID) -> Bool {
        unresponsiveShares.contains(id)
    }

    func missStreak(_ id: UUID) -> Int {
        missStreaks[id] ?? 0
    }

    mutating func record(
        _ probe: VolumeProbe,
        for id: UUID,
        isEnabled: Bool,
        autoMount: Bool
    ) -> ShareHealthChange {
        var change = ShareHealthChange()
        switch probe {
        case .unresponsive:
            change.becameUnresponsive = unresponsiveShares.insert(id).inserted
            let streak = policy.misses(after: probe, current: missStreaks[id] ?? 0)
            missStreaks[id] = streak
            change.shouldRepair = policy.shouldRepair(
                misses: streak,
                isEnabled: isEnabled,
                autoMount: autoMount
            )
        case .usage:
            change.recovered = unresponsiveShares.remove(id) != nil
            missStreaks[id] = nil
        case .busy, .unavailable:
            break
        }
        return change
    }

    /// Bytes moving through a session are proof that the share answers, so
    /// activity clears both the mark and the streak.
    mutating func noteActivity(_ id: UUID) -> Bool {
        missStreaks[id] = nil
        return unresponsiveShares.remove(id) != nil
    }

    mutating func clear(_ id: UUID) {
        unresponsiveShares.remove(id)
        missStreaks[id] = nil
    }
}

// MARK: - Formatting

enum ByteFormatting {
    /// Decimal units, one decimal below ten: 3.2T, 18T, 640G, 12M.
    static func short(_ bytes: UInt64) -> String {
        let units: [(Double, String)] = [(1e12, "T"), (1e9, "G"), (1e6, "M"), (1e3, "K")]
        let value = Double(bytes)
        for (scale, suffix) in units where value >= scale {
            let scaled = value / scale
            let text = scaled < 10
                ? String(format: "%.1f", scaled).replacingOccurrences(of: ".0", with: "")
                : String(Int(scaled.rounded()))
            return text + suffix
        }
        return "\(bytes)B"
    }

    /// A transfer rate such as 120MB/s, or nil below one kilobyte a second.
    static func rate(_ bytesPerSecond: Double) -> String? {
        guard bytesPerSecond >= 1_000 else { return nil }
        return short(UInt64(bytesPerSecond)) + "B/s"
    }
}

/// Bytes per second between two samples of the same session counters.
struct TrafficRate: Equatable, Sendable {
    let received: Double
    let sent: Double

    init(received: Double, sent: Double) {
        self.received = received
        self.sent = sent
    }

    init(from old: SMBSession, to new: SMBSession, seconds: Double) {
        guard seconds > 0 else {
            received = 0
            sent = 0
            return
        }
        // Counters restart with a reconnected session; that interval reads as idle.
        received = new.receivedBytes >= old.receivedBytes
            ? Double(new.receivedBytes - old.receivedBytes) / seconds : 0
        sent = new.sentBytes >= old.sentBytes
            ? Double(new.sentBytes - old.sentBytes) / seconds : 0
    }

    /// Whether either direction is above the display threshold. Below one
    /// kilobyte a second the figure is noise, not activity.
    var isActive: Bool {
        received >= 1_000 || sent >= 1_000
    }

    /// Two rates of sessions on one host add up.
    func adding(_ other: TrafficRate) -> TrafficRate {
        TrafficRate(received: received + other.received, sent: sent + other.sent)
    }

    /// Compact enough for a fixed slot in the host header.
    var label: String? {
        guard isActive else { return nil }
        var parts: [String] = []
        if received >= 1_000 {
            parts.append("↓\(ByteFormatting.short(UInt64(received)))")
        }
        if sent >= 1_000 {
            parts.append("↑\(ByteFormatting.short(UInt64(sent)))")
        }
        return parts.joined(separator: " ")
    }

    var detail: String? {
        guard isActive else { return nil }
        let parts = [
            ByteFormatting.rate(received).map { "\($0) received" },
            ByteFormatting.rate(sent).map { "\($0) sent" }
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// Turns two samples of the session counters into one rate per host.
enum HostTraffic {
    struct Sample: Equatable, Sendable {
        var rates: [String: TrafficRate] = [:]
        var activeShareIDs: Set<UUID> = []
    }

    /// Sums the sessions of every mounted share on a host. Two configurations
    /// can resolve to one mount, so a path counts once but still counts as
    /// activity for both.
    static func sample(
        from previous: [String: SMBSession],
        to current: [String: SMBSession],
        seconds: Double,
        over shares: [ShareConfiguration],
        path: (ShareConfiguration) -> String
    ) -> Sample {
        var sample = Sample()
        var counted: Set<String> = []
        for share in shares {
            let mountPath = path(share)
            guard let old = previous[mountPath], let new = current[mountPath] else { continue }
            let rate = TrafficRate(from: old, to: new, seconds: seconds)
            if rate.isActive {
                sample.activeShareIDs.insert(share.id)
            }
            guard counted.insert(mountPath).inserted else { continue }
            let key = hostKey(share.host)
            sample.rates[key] = sample.rates[key].map { $0.adding(rate) } ?? rate
        }
        return sample
    }

    /// Hosts are compared the same way the manager compares them.
    static func hostKey(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - URL commands

/// What a `sharebeacon://` link asks for.
enum ShareBeaconCommand: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case share(String)
        case host(String)
        /// A named share on a named host. Commands that change a mount require
        /// this, so a link cannot hit every server that has a share of the
        /// same name.
        case exact(host: String, share: String)
        case all
    }

    case mount(Target)
    case unmount(Target)
    case remount(Target)
    case open(String)
    case settings
    case log

    /// Accepts `sharebeacon://mount-all`, `sharebeacon://mount?share=Name`,
    /// `sharebeacon://mount?host=nas`, `sharebeacon://unmount?host=nas&share=Name`,
    /// `sharebeacon://remount?host=nas&share=Name`, `sharebeacon://open?share=Name`,
    /// `sharebeacon://settings` and `sharebeacon://log`. Commands that change a
    /// mount need both host and share: a bare share name would match every
    /// server that uses it, and a bare host would unmount all of its shares.
    init?(url: URL) {
        guard url.scheme?.lowercased() == "sharebeacon",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let action = (components.host ?? components.path)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        let query = Dictionary(
            (components.queryItems ?? []).compactMap { item in item.value.map { (item.name.lowercased(), $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        func value(_ key: String) -> String? {
            guard let text = query[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { return nil }
            return text
        }
        let shareName = value("share")
        let hostName = value("host")
        let exact: Target? = {
            guard let shareName, let hostName else { return nil }
            return .exact(host: hostName, share: shareName)
        }()

        switch action {
        case "mount-all": self = .mount(.all)
        case "mount":
            guard let target = exact
                ?? shareName.map(Target.share)
                ?? hostName.map(Target.host)
            else { return nil }
            self = .mount(target)
        case "unmount": guard let exact else { return nil }; self = .unmount(exact)
        case "remount": guard let exact else { return nil }; self = .remount(exact)
        case "open": guard let name = shareName else { return nil }; self = .open(name)
        case "settings": self = .settings
        case "log": self = .log
        default: return nil
        }
    }

    /// Whether a configured share is meant by a target.
    static func matches(_ target: Target, _ share: ShareConfiguration) -> Bool {
        switch target {
        case .all:
            return true
        case .share(let name):
            return share.name.caseInsensitiveCompare(name) == .orderedSame
                || share.shareName.caseInsensitiveCompare(name) == .orderedSame
        case .host(let host):
            return share.host.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(host) == .orderedSame
        case .exact(let host, let name):
            return matches(.host(host), share)
                && (share.name.caseInsensitiveCompare(name) == .orderedSame
                    || share.shareName.caseInsensitiveCompare(name) == .orderedSame)
        }
    }
}
