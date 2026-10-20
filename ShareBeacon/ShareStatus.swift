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
    static func read(timeout: TimeInterval = 5) -> [SMBSession] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/smbutil")
        process.arguments = ["multichannel", "-a"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }

        let output = Mutex(Data())
        let reader = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            output.withLock { $0 = data }
            reader.signal()
        }
        guard reader.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return []
        }
        process.waitUntilExit()
        return SMBSession.parse(String(decoding: output.withLock { $0 }, as: UTF8.self))
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
    case unavailable
}

enum VolumeProber {
    /// Asks the file system for its size on a separate thread and gives up
    /// after `timeout`. A probe that is still stuck is not started again, so
    /// a hung share holds at most one thread.
    static func probe(path: String, timeout: TimeInterval = 4) -> VolumeProbe {
        let claimed = inFlight.withLock { $0.insert(path).inserted }
        guard claimed else { return .unresponsive }

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
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return .unresponsive }
        return result.withLock { $0 } ?? .unavailable
    }

    private static let inFlight = Mutex(Set<String>())
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

    /// A transfer rate such as 120 MB/s, or nil below one kilobyte a second.
    static func rate(_ bytesPerSecond: Double) -> String? {
        guard bytesPerSecond >= 1_000 else { return nil }
        return short(UInt64(bytesPerSecond)) + "B/s"
    }
}

/// Bytes per second between two samples of the same session counters.
struct TrafficRate: Equatable, Sendable {
    let received: Double
    let sent: Double

    static let idle = TrafficRate(received: 0, sent: 0)

    init(received: Double, sent: Double) {
        self.received = received
        self.sent = sent
    }

    init(from old: SMBSession, to new: SMBSession, seconds: Double) {
        guard seconds > 0 else {
            self = .idle
            return
        }
        // Counters restart with a reconnected session; that interval reads as idle.
        received = new.receivedBytes >= old.receivedBytes
            ? Double(new.receivedBytes - old.receivedBytes) / seconds : 0
        sent = new.sentBytes >= old.sentBytes
            ? Double(new.sentBytes - old.sentBytes) / seconds : 0
    }

    var label: String? {
        let parts = [
            ByteFormatting.rate(received).map { "↓\($0)" },
            ByteFormatting.rate(sent).map { "↑\($0)" }
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

// MARK: - URL commands

/// What a `sharebeacon://` link asks for.
enum ShareBeaconCommand: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case share(String)
        case host(String)
        case all
    }

    case mount(Target)
    case unmount(Target)
    case remount(Target)
    case open(String)
    case settings
    case log

    /// Accepts `sharebeacon://mount-all`, `sharebeacon://unmount-all`,
    /// `sharebeacon://mount?share=Name`, `sharebeacon://unmount?host=nas`,
    /// `sharebeacon://remount?share=Name`, `sharebeacon://open?share=Name`,
    /// `sharebeacon://settings` and `sharebeacon://log`.
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
        let target: Target? = query["share"].map(Target.share) ?? query["host"].map(Target.host)

        switch action {
        case "mount-all": self = .mount(.all)
        case "unmount-all": self = .unmount(.all)
        case "remount-all": self = .remount(.all)
        case "mount": guard let target else { return nil }; self = .mount(target)
        case "unmount": guard let target else { return nil }; self = .unmount(target)
        case "remount": guard let target else { return nil }; self = .remount(target)
        case "open": guard let name = query["share"] else { return nil }; self = .open(name)
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
        }
    }
}
