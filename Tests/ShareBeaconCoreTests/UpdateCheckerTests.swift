import Foundation
import Synchronization
import Testing
@testable import ShareBeaconCore

@Suite("Update checker")
struct UpdateCheckerTests {
    @Test("release versions compare numerically")
    func releaseVersionsCompareNumerically() {
        #expect(ReleaseVersion("v1.10")! > ReleaseVersion("1.9")!)
        #expect(ReleaseVersion("1.1") == ReleaseVersion(" v1.1 "))
        #expect(ReleaseVersion("1.1.0") == nil)
        #expect(ReleaseVersion("v") == nil)
        #expect(ReleaseVersion("1.-1") == nil)
    }

    @Test("a newer release becomes an available update")
    @MainActor
    func newerReleaseIsAvailable() async {
        let suite = "ShareBeaconUpdateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = URL(string: "https://example.test/releases/v1.2")!
        let now = Date(timeIntervalSince1970: 1_000)
        let checker = UpdateChecker(
            currentVersion: "1.1",
            defaults: defaults,
            fetch: {
                LatestRelease(version: ReleaseVersion("1.2")!, releaseURL: url)
            },
            now: { now }
        )

        await checker.check()

        #expect(checker.availableUpdate == AppUpdate(
            version: ReleaseVersion("1.2")!,
            releaseURL: url
        ))
        #expect(checker.lastChecked == now)
        #expect(defaults.object(forKey: "shareBeaconLastUpdateCheck") as? Date == now)
    }

    @Test("the current release is reported as up to date")
    @MainActor
    func currentReleaseIsUpToDate() async {
        let suite = "ShareBeaconUpdateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let checker = UpdateChecker(
            currentVersion: "1.2",
            defaults: defaults,
            fetch: {
                LatestRelease(
                    version: ReleaseVersion("1.1")!,
                    releaseURL: URL(string: "https://example.test/releases/v1.1")!
                )
            }
        )

        await checker.check()

        #expect(checker.state == .upToDate)
        #expect(checker.availableUpdate == nil)
    }

    @Test("a recent successful check is reused")
    @MainActor
    func recentCheckIsReused() async {
        let suite = "ShareBeaconUpdateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let calls = Mutex(0)
        let now = Date(timeIntervalSince1970: 2_000)
        let checker = UpdateChecker(
            currentVersion: "1.1",
            defaults: defaults,
            fetch: {
                calls.withLock { $0 += 1 }
                return LatestRelease(
                    version: ReleaseVersion("1.2")!,
                    releaseURL: URL(string: "https://example.test/releases/v1.2")!
                )
            },
            now: { now }
        )

        await checker.check()
        await checker.checkIfNeeded()

        #expect(calls.withLock { $0 } == 1)
    }

    @Test("a failed check waits before trying again")
    @MainActor
    func failedCheckIsThrottled() async {
        struct CheckFailure: Error {}
        let suite = "ShareBeaconUpdateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let calls = Mutex(0)
        let checker = UpdateChecker(
            currentVersion: "1.1",
            defaults: defaults,
            fetch: {
                calls.withLock { $0 += 1 }
                throw CheckFailure()
            },
            now: { Date(timeIntervalSince1970: 3_000) }
        )

        await checker.check()
        await checker.checkIfNeeded()

        #expect(checker.state == .failed)
        #expect(checker.availableUpdate == nil)
        #expect(calls.withLock { $0 } == 1)
    }
}
