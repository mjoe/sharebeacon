import Foundation

/// Decides when an automatic status refresh may run. The menu panel asks
/// every ten seconds, while probes are calls into the SMB client, so the
/// manager needs a floor between them.
struct StatusRefreshPolicy: Equatable, Sendable {
    let minimumInterval: TimeInterval

    init(minimumInterval: TimeInterval = 15) {
        self.minimumInterval = minimumInterval
    }

    /// The delay a call has to wait, or nil when it may run now. A clock that
    /// moved backwards waits a full interval instead of spinning.
    func delay(lastRefresh: Date, now: Date) -> TimeInterval? {
        let elapsed = now.timeIntervalSince(lastRefresh)
        guard elapsed < minimumInterval else { return nil }
        return minimumInterval - max(elapsed, 0)
    }
}

/// The part of the wake handling that needs no notifications: wait out a
/// grace period, then reconnect once the network path has stayed quiet long
/// enough. Wi-Fi often reports "satisfied" before it can carry SMB.
struct WakePolicy: Equatable, Sendable {
    let grace: TimeInterval
    let stableInterval: TimeInterval
    let maximumWait: TimeInterval

    init(
        grace: TimeInterval = 5,
        stableInterval: TimeInterval = 10,
        maximumWait: TimeInterval = 40
    ) {
        self.grace = grace
        self.stableInterval = stableInterval
        self.maximumWait = maximumWait
    }

    /// Whether the path has been quiet long enough to reconnect.
    func isSettled(lastChange: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastChange) >= stableInterval
    }

    /// Whether the wait has run out and shares should be reconnected anyway.
    func shouldGiveUp(waited: TimeInterval) -> Bool {
        waited >= maximumWait
    }
}
