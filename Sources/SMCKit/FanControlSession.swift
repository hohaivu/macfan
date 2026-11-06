import Foundation

/// Who owns the fans, as the privileged helper sees it.
///
/// The rules, each of which exists because getting it wrong leaves fans stuck in manual:
/// - Control counts as taken *before* the first write, because a write that fails halfway
///   may already have switched a fan to manual.
/// - Control is released only after macOS confirmably has every fan back.
/// - A failed target write hands every fan back immediately.
/// - Only successful writes count as a heartbeat; a client stuck retrying failed writes
///   must not keep the watchdog away.
/// - The watchdog keeps retrying a hand-back that failed.
/// - A failed hand-back counts as control, even if this session never wrote, so the watchdog retries it.
///
/// Not thread-safe: the helper confines it to one serial queue.
public final class FanControlSession<SMC: SMCKeyAccess> {
    public private(set) var isControlling = false

    private let fans: SMCFanControl<SMC>
    private let watchdogTimeout: TimeInterval
    private var lastHeartbeat = Date.distantPast

    public init(fans: SMCFanControl<SMC>, watchdogTimeout: TimeInterval) {
        self.fans = fans
        self.watchdogTimeout = watchdogTimeout
    }

    /// Sets one fan's target. On failure, tries to hand every fan back, then rethrows the
    /// original error.
    public func setTarget(rpm: Double, fan index: Int, at now: Date) throws {
        guard rpm.isFinite, (0..<(try fans.fanCount())).contains(index) else {
            throw SMCError.invalidFanData("fan \(index), target \(rpm) rpm")
        }
        isControlling = true
        do {
            try fans.setTarget(rpm: rpm, fan: index)
            lastHeartbeat = now
        } catch {
            try? restore()
            throw error
        }
    }

    /// Hands every fan back to macOS. Throws, and stays in control, if any fan may still be manual.
    public func restore() throws {
        do { try fans.restoreAutomatic() } catch { isControlling = true; throw error }
        isControlling = false
        lastHeartbeat = .distantPast
    }

    public enum WatchdogOutcome: Equatable, Sendable {
        /// Nothing to do: not in control, or the client is still sending commands.
        case idle
        case returnedFans
        /// The hand-back failed; the next check tries again.
        case restoreFailed
    }

    /// Hands the fans back when the client has been silent too long. Retries on every call
    /// until a hand-back succeeds.
    @discardableResult
    public func checkWatchdog(at now: Date) -> WatchdogOutcome {
        guard isControlling, now.timeIntervalSince(lastHeartbeat) > watchdogTimeout else { return .idle }
        do {
            try restore()
            return .returnedFans
        } catch {
            return .restoreFailed
        }
    }
}
