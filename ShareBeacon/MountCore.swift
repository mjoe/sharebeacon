import Foundation
import Darwin
import Network
import Security
import NetFS

enum ShareBeaconError: LocalizedError, Equatable {
    case invalidConfiguration(String)
    case credentialMissing
    case endpointUnavailable
    case mountFailed(Int32)
    case unmountFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return message
        case .credentialMissing:
            return "No password is stored in Keychain for this share."
        case .endpointUnavailable:
            return "The SMB endpoint is not reachable."
        case .mountFailed(let status):
            if status == 17 {
                return "A volume is already mounted at this location (NetFS status 17)."
            }
            return "macOS could not mount the share (NetFS status \(status))."
        case .unmountFailed(let status):
            return "macOS could not unmount the share (status \(status))."
        }
    }
}

struct ShareConfiguration: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var host: String
    var shareName: String
    var username: String
    var mountPoint: String
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        shareName: String,
        username: String,
        mountPoint: String,
        isEnabled: Bool
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.shareName = shareName
        self.username = username
        self.mountPoint = mountPoint
        self.isEnabled = isEnabled
    }

    static func defaultShare(homeDirectory: String = NSHomeDirectory()) -> ShareConfiguration {
        ShareConfiguration(
            name: "NAS Data",
            host: "nas.taila7f773.ts.net",
            shareName: "data",
            username: "ubani",
            mountPoint: URL(fileURLWithPath: homeDirectory)
                .appendingPathComponent("Volumes/data")
                .path,
            isEnabled: true
        )
    }

    static func validate(_ shares: [ShareConfiguration]) throws {
        var identifiers = Set<UUID>()
        var mountPoints = Set<String>()

        for share in shares {
            guard identifiers.insert(share.id).inserted else {
                throw ShareBeaconError.invalidConfiguration("Share identifiers must be unique.")
            }

            let host = share.host.trimmingCharacters(in: .whitespacesAndNewlines)
            let shareName = share.shareName.trimmingCharacters(in: .whitespacesAndNewlines)
            let mountPoint = standardizedPath(share.mountPoint)

            guard !host.isEmpty, !shareName.isEmpty, !mountPoint.isEmpty else {
                throw ShareBeaconError.invalidConfiguration(
                    "Host, share name, and mount point are required."
                )
            }
            guard !host.contains("/") && !host.contains("@") else {
                throw ShareBeaconError.invalidConfiguration("Host contains invalid characters.")
            }
            guard !shareName.contains("/") else {
                throw ShareBeaconError.invalidConfiguration(
                    "Nested SMB paths are not supported; enter the share name only."
                )
            }
            guard mountPoints.insert(mountPoint).inserted else {
                throw ShareBeaconError.invalidConfiguration(
                    "Each share must use a unique mount point."
                )
            }
        }
    }

    func smbURL() throws -> URL {
        var components = URLComponents()
        components.scheme = "smb"
        components.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        components.path = "/" + shareName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = components.url else {
            throw ShareBeaconError.invalidConfiguration("The SMB URL is invalid.")
        }
        return url
    }

    var normalizedMountPoint: String {
        Self.standardizedPath(mountPoint)
    }

    var mountIdentity: String {
        [
            host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            shareName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            normalizedMountPoint
        ].joined(separator: "\u{1f}")
    }

    private static func standardizedPath(_ path: String) -> String {
        let expanded: String
        if path == "~" {
            expanded = NSHomeDirectory()
        } else if path.hasPrefix("~/") {
            expanded = NSHomeDirectory() + String(path.dropFirst())
        } else {
            expanded = path
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
}

struct MountTable: Sendable {
    private struct Entry: Sendable {
        let source: String
        let mountPoint: String
    }

    private let entries: [Entry]

    init(output: String) {
        entries = output.split(separator: "\n").compactMap { line in
            let value = String(line)
            guard value.contains("(smbfs"), let separator = value.range(of: " on ") else {
                return nil
            }
            let source = String(value[..<separator.lowerBound])
            let suffix = value[separator.upperBound...]
            let mountPoint = suffix.components(separatedBy: " (").first ?? String(suffix)
            return Entry(source: source, mountPoint: mountPoint)
        }
    }

    private init(entries: [Entry]) {
        self.entries = entries
    }

    private func hostComponent(from source: String) -> String {
        var value = (source.removingPercentEncoding ?? source).lowercased()
        if value.hasPrefix("//") {
            value.removeFirst(2)
        }
        if let atIndex = value.firstIndex(of: "@") {
            value = String(value[value.index(after: atIndex)...])
        }
        if let slashIndex = value.firstIndex(of: "/") {
            value = String(value[..<slashIndex])
        }
        return value
    }

    private func shareComponent(from source: String) -> String {
        var value = (source.removingPercentEncoding ?? source).lowercased()
        if value.hasPrefix("//") {
            value.removeFirst(2)
        }
        if let atIndex = value.firstIndex(of: "@") {
            value = String(value[value.index(after: atIndex)...])
        }
        if let slashIndex = value.firstIndex(of: "/") {
            return String(value[value.index(after: slashIndex)...])
        }
        return value
    }

    private func normalizedMountPoint(_ value: String) -> String {
        let decoded = value.removingPercentEncoding ?? value
        return URL(fileURLWithPath: decoded).standardizedFileURL.path
    }

    private func matches(_ entry: Entry, host: String, share: String) -> Bool {
        let configuredShare = share.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard shareComponent(from: entry.source) == configuredShare else {
            return false
        }
        let configuredHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let entryHost = hostComponent(from: entry.source)
        if entryHost == configuredHost {
            return true
        }
        let entryAddresses = Self.resolvedAddresses(for: entryHost)
        let configuredAddresses = Self.resolvedAddresses(for: configuredHost)
        if !entryAddresses.isEmpty, !configuredAddresses.isEmpty,
           !Set(entryAddresses).isDisjoint(with: configuredAddresses) {
            return true
        }
        return false
    }

    func isMounted(host: String, share: String, at mountPoint: String) -> Bool {
        let expectedMountPoint = URL(fileURLWithPath: mountPoint).standardizedFileURL.path
        return entries.contains { entry in
            matches(entry, host: host, share: share)
                && normalizedMountPoint(entry.mountPoint) == expectedMountPoint
        }
    }

    func mountPoint(host: String, share: String) -> String? {
        entries.first(where: { matches($0, host: host, share: share) })
            .map { normalizedMountPoint($0.mountPoint) }
    }

    func mountPoint(forShareNamed share: String) -> String? {
        let expected = share.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries.first(where: { shareComponent(from: $0.source) == expected })
            .map { normalizedMountPoint($0.mountPoint) }
    }

    nonisolated(unsafe) private static var resolutionCache: [String: [String]] = [:]
    private static let resolutionLock = NSLock()

    private static func resolvedAddresses(for host: String) -> [String] {
        let key = host.lowercased()
        resolutionLock.lock()
        if let cached = resolutionCache[key] {
            resolutionLock.unlock()
            return cached
        }
        resolutionLock.unlock()

        var addresses: [String] = []
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0 else {
            resolutionLock.lock()
            resolutionCache[key] = []
            resolutionLock.unlock()
            return []
        }
        defer { freeaddrinfo(result) }

        var cursor = result
        while let current = cursor {
            guard let address = current.pointee.ai_addr else {
                cursor = current.pointee.ai_next
                continue
            }
            let family = address.pointee.sa_family
            var storage = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))

            let presentation: UnsafePointer<CChar>?
            if family == AF_INET {
                let sin = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var addressBytes = sin.sin_addr
                presentation = inet_ntop(
                    AF_INET,
                    &addressBytes,
                    &storage,
                    socklen_t(storage.count)
                )
            } else if family == AF_INET6 {
                let sin6 = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                var addressBytes = sin6.sin6_addr
                presentation = inet_ntop(
                    AF_INET6,
                    &addressBytes,
                    &storage,
                    socklen_t(storage.count)
                )
            } else {
                presentation = nil
            }

            if let presentation {
                addresses.append(String(cString: presentation))
            }
            cursor = current.pointee.ai_next
        }

        resolutionLock.lock()
        resolutionCache[key] = addresses
        resolutionLock.unlock()
        return addresses
    }

    static func current() -> MountTable {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard let mounts, count > 0 else {
            return MountTable(entries: [])
        }

        let entries = (0..<Int(count)).compactMap { index -> Entry? in
            var mount = mounts[index]
            let fileSystemType = withUnsafePointer(to: &mount.f_fstypename) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<statfs>.size) {
                    String(cString: $0)
                }
            }
            guard fileSystemType == "smbfs" else { return nil }

            let source = withUnsafePointer(to: &mount.f_mntfromname) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<statfs>.size) {
                    String(cString: $0)
                }
            }
            let mountPoint = withUnsafePointer(to: &mount.f_mntonname) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<statfs>.size) {
                    String(cString: $0)
                }
            }
            return Entry(source: source, mountPoint: mountPoint)
        }
        return MountTable(entries: entries)
    }
}

protocol CredentialStoring: Sendable {
    func save(password: String, for share: ShareConfiguration) throws
    func password(for share: ShareConfiguration) throws -> String?
    func deletePassword(for share: ShareConfiguration) throws
}

final class KeychainCredentialStore: CredentialStoring, @unchecked Sendable {
    static let shared = KeychainCredentialStore()
    private let service = "com.mjoe.sharebeacon.smb"

    private func query(for share: ShareConfiguration) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: share.id.uuidString
        ]
    }

    func save(password: String, for share: ShareConfiguration) throws {
        var lookup = query(for: share)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let updateStatus = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus))
        }

        attributes.forEach { lookup[$0.key] = $0.value }
        let addStatus = SecItemAdd(lookup as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
        }
    }

    func password(for share: ShareConfiguration) throws -> String? {
        var lookup = query(for: share)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return String(data: data, encoding: .utf8)
    }

    func deletePassword(for share: ShareConfiguration) throws {
        let status = SecItemDelete(query(for: share) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}

protocol EndpointChecking: Sendable {
    func isReachable(host: String, port: UInt16, timeout: TimeInterval) async -> Bool
}

struct SMBEndpointChecker: EndpointChecking {
    func isReachable(host: String, port: UInt16 = 445, timeout: TimeInterval) async -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            return false
        }

        return await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "com.mjoe.sharebeacon.endpoint-check")
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: endpointPort,
                using: .tcp
            )
            let completion = EndpointCheckCompletion(
                connection: connection,
                continuation: continuation
            )

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    completion.finish(true)
                case .failed, .cancelled:
                    completion.finish(false)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                completion.finish(false)
            }
        }
    }
}

private final class EndpointCheckCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let connection: NWConnection
    private var continuation: CheckedContinuation<Bool, Never>?

    init(
        connection: NWConnection,
        continuation: CheckedContinuation<Bool, Never>
    ) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish(_ result: Bool) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()

        connection.cancel()
        continuation.resume(returning: result)
    }
}

protocol ShareMounting: Sendable {
    func mount(_ share: ShareConfiguration, password: String) throws
    func unmount(_ share: ShareConfiguration, at mountPoint: String) throws
}

struct NetFSShareMounter: ShareMounting {
    func mount(_ share: ShareConfiguration, password: String) throws {
        let mountPoint = share.normalizedMountPoint
        try FileManager.default.createDirectory(
            atPath: mountPoint,
            withIntermediateDirectories: true
        )

        let url = try share.smbURL() as CFURL
        let mountURL = URL(fileURLWithPath: mountPoint, isDirectory: true) as CFURL
        let openOptions = NSMutableDictionary(dictionary: [
            kNAUIOptionKey as String: kNAUIOptionNoUI
        ])
        let mountOptions = NSMutableDictionary(dictionary: [
            kNetFSSoftMountKey as String: true,
            kNetFSMountAtMountDirKey as String: true
        ])
        var mountPoints: Unmanaged<CFArray>?

        let status = NetFSMountURLSync(
            url,
            mountURL,
            share.username as CFString,
            password as CFString,
            openOptions,
            mountOptions,
            &mountPoints
        )
        mountPoints?.release()

        guard status == 0 else {
            throw ShareBeaconError.mountFailed(status)
        }
    }

    func unmount(_ share: ShareConfiguration, at mountPoint: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["unmount", mountPoint]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ShareBeaconError.unmountFailed(process.terminationStatus)
        }
    }
}
