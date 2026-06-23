import Foundation
import Network
import Security
import NetFS

enum MountJockeyError: LocalizedError, Equatable {
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
                throw MountJockeyError.invalidConfiguration("Share identifiers must be unique.")
            }

            let host = share.host.trimmingCharacters(in: .whitespacesAndNewlines)
            let shareName = share.shareName.trimmingCharacters(in: .whitespacesAndNewlines)
            let mountPoint = standardizedPath(share.mountPoint)

            guard !host.isEmpty, !shareName.isEmpty, !mountPoint.isEmpty else {
                throw MountJockeyError.invalidConfiguration(
                    "Host, share name, and mount point are required."
                )
            }
            guard !host.contains("/") && !host.contains("@") else {
                throw MountJockeyError.invalidConfiguration("Host contains invalid characters.")
            }
            guard !shareName.contains("/") else {
                throw MountJockeyError.invalidConfiguration(
                    "Nested SMB paths are not supported; enter the share name only."
                )
            }
            guard mountPoints.insert(mountPoint).inserted else {
                throw MountJockeyError.invalidConfiguration(
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
            throw MountJockeyError.invalidConfiguration("The SMB URL is invalid.")
        }
        return url
    }

    var normalizedMountPoint: String {
        Self.standardizedPath(mountPoint)
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

    func isMounted(host: String, share: String, at mountPoint: String) -> Bool {
        let expectedMountPoint = URL(fileURLWithPath: mountPoint).standardizedFileURL.path
        let rawExpectedSource = "//\(host.lowercased())/\(share)"
        let expectedSource = (rawExpectedSource.removingPercentEncoding ?? rawExpectedSource)
            .lowercased()

        return entries.contains { entry in
            let decodedSource = (entry.source.removingPercentEncoding ?? entry.source).lowercased()
            let decodedMountPoint = entry.mountPoint.removingPercentEncoding ?? entry.mountPoint
            let normalizedMountPoint = URL(fileURLWithPath: decodedMountPoint)
                .standardizedFileURL.path

            let sourceWithoutUser: String
            if let atIndex = decodedSource.firstIndex(of: "@") {
                sourceWithoutUser = "//" + decodedSource[decodedSource.index(after: atIndex)...]
            } else {
                sourceWithoutUser = decodedSource
            }

            return sourceWithoutUser == expectedSource && normalizedMountPoint == expectedMountPoint
        }
    }

    static func current() -> MountTable {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/mount")
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return MountTable(output: String(data: data, encoding: .utf8) ?? "")
        } catch {
            return MountTable(output: "")
        }
    }
}

protocol CredentialStoring: Sendable {
    func save(password: String, for share: ShareConfiguration) throws
    func password(for share: ShareConfiguration) throws -> String?
    func deletePassword(for share: ShareConfiguration) throws
}

final class KeychainCredentialStore: CredentialStoring, @unchecked Sendable {
    static let shared = KeychainCredentialStore()
    private let service = "com.valmayaki.mountjockey.smb"

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
            let queue = DispatchQueue(label: "com.valmayaki.mountjockey.endpoint-check")
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
    func unmount(_ share: ShareConfiguration) throws
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
            throw MountJockeyError.mountFailed(status)
        }
    }

    func unmount(_ share: ShareConfiguration) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["unmount", share.normalizedMountPoint]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw MountJockeyError.unmountFailed(process.terminationStatus)
        }
    }
}
