import Foundation
import Observation

/// The two-part version ShareBeacon uses for releases. Parsing accepts the
/// leading `v` from a tag and compares numerically, so `1.10` is newer than
/// `1.9` rather than older as plain text would suggest.
struct ReleaseVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int

    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.lowercased().hasPrefix("v")
            ? String(trimmed.dropFirst())
            : trimmed
        let parts = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              major >= 0,
              minor >= 0
        else { return nil }
        self.major = major
        self.minor = minor
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        return lhs.minor < rhs.minor
    }

    var description: String {
        "\(major).\(minor)"
    }
}

struct LatestRelease: Equatable, Sendable {
    let version: ReleaseVersion
    let releaseURL: URL
}

struct AppUpdate: Equatable, Sendable {
    let version: ReleaseVersion
    let releaseURL: URL
}

/// Asks GitHub for the latest published release. The unauthenticated API is
/// enough for one check per launch, and the request falls back to no update
/// when the network, the API or the tag is not usable.
struct GitHubReleaseFetcher: Sendable {
    private static let endpoint = URL(
        string: "https://api.github.com/repos/mjoe/sharebeacon/releases/latest"
    )!

    func latestRelease() async throws -> LatestRelease {
        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("ShareBeacon", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200
        else { throw URLError(.badServerResponse) }

        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let version = ReleaseVersion(payload.tagName),
              let releaseURL = payload.htmlURL
        else { throw URLError(.cannotParseResponse) }
        return LatestRelease(version: version, releaseURL: releaseURL)
    }

    private struct Payload: Decodable {
        let tagName: String
        let htmlURL: URL?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }
}

/// Holds the result of the update check for the panel and the settings window.
/// A successful check is reused for a day, a failed one for an hour, so opening
/// the panel repeatedly does not turn into repeated GitHub requests.
@MainActor
@Observable
final class UpdateChecker {
    enum State: Equatable, Sendable {
        case idle
        case checking
        case upToDate
        case available(AppUpdate)
        case failed
    }

    private(set) var state: State = .idle
    private(set) var lastChecked: Date?
    private(set) var failureMessage: String?

    @ObservationIgnored private let currentVersion: ReleaseVersion?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fetch: @Sendable () async throws -> LatestRelease
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var lastAttempt: Date?

    private static let lastCheckKey = "shareBeaconLastUpdateCheck"
    private let successInterval: TimeInterval = 24 * 60 * 60
    private let failureInterval: TimeInterval = 60 * 60

    init(
        currentVersion: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.0",
        defaults: UserDefaults = .standard,
        fetch: @escaping @Sendable () async throws -> LatestRelease = {
            try await GitHubReleaseFetcher().latestRelease()
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.currentVersion = ReleaseVersion(currentVersion)
        self.defaults = defaults
        self.fetch = fetch
        self.now = now
        self.lastChecked = defaults.object(forKey: Self.lastCheckKey) as? Date
    }

    var availableUpdate: AppUpdate? {
        guard case .available(let update) = state else { return nil }
        return update
    }

    var isChecking: Bool {
        state == .checking
    }

    /// Runs only when the last successful check is old enough, or when the
    /// last failed attempt is old enough to try again.
    func checkIfNeeded() async {
        guard state != .checking else { return }
        let current = now()
        if let lastChecked,
           current.timeIntervalSince(lastChecked) < successInterval {
            return
        }
        if let lastAttempt,
           current.timeIntervalSince(lastAttempt) < failureInterval {
            return
        }
        await check()
    }

    /// Runs a check now, regardless of the cached result.
    func check() async {
        guard state != .checking else { return }
        guard let currentVersion else {
            state = .failed
            failureMessage = "The current version could not be read."
            return
        }

        state = .checking
        failureMessage = nil
        lastAttempt = now()
        do {
            let release = try await fetch()
            if release.version > currentVersion {
                state = .available(
                    AppUpdate(version: release.version, releaseURL: release.releaseURL)
                )
            } else {
                state = .upToDate
            }
            let checked = now()
            lastChecked = checked
            defaults.set(checked, forKey: Self.lastCheckKey)
        } catch {
            state = .failed
            failureMessage = error.localizedDescription
        }
    }
}
