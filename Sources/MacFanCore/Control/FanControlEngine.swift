import Foundation
import Observation

/// Sends fan commands to whatever can execute them: the privileged helper in the app,
/// a fake in tests.
@MainActor
public protocol FanCommanding {
    var isReady: Bool { get }
    func setTarget(rpm: Double, fanIndex: Int) async throws
    func restoreSystemControl() async throws
    /// A bounded, synchronous hand-back for app termination, when async work can't finish.
    func restoreSystemControlBlocking()
}

/// Applies `CoolingPlanner` decisions to the hardware.
///
/// Fans are handed back to macOS when the user picks Automatic, during
/// missing data, before sleep, after a failed write, and on quit. The helper independently
/// does the same if the app vanishes or goes silent. During an emergency in Fixed or Curve mode
/// it runs every fan at full speed instead, unless the user opted to keep their setting.
///
/// The rules that keep that promise:
/// - `mayBeControlling` is set *before* the first write and cleared only after macOS
///   confirms it has the fans back, so no failure path loses the obligation to restore.
/// - A failed hand-back stays visible (`.failed`) and is retried on the next tick.
/// - `suspend()` invalidates any update in flight; an update checks after every `await`,
///   so no target can follow the hand-back.
@MainActor
@Observable
public final class FanControlEngine {
    public enum State: Equatable, Sendable {
        /// macOS is in charge.
        case system
        /// A part is critically hot or macOS reports critical pressure; MacFan runs every fan at full speed until both have eased.
        case emergency
        /// There's no temperature data to act on; macOS is in charge.
        case noData
        /// MacFan is driving the fans at this 0…1 speed.
        case controlling(speed: Double)
        /// The chosen mode needs the helper, which isn't ready.
        case needsHelper
        case failed(String)
    }

    public private(set) var state: State = .system
    /// The temperature the curve is reacting to right now.
    public private(set) var curveTemperature: Double?
    /// Either emergency latch is set, whatever the decision. Lets the UI warn when the user chose to keep their setting.
    public private(set) var isCriticallyHot = false

    @ObservationIgnored private var planner = CoolingPlanner()
    /// Starts `true` so a leftover manual state from a crash is cleared on the first tick.
    @ObservationIgnored private var mayBeControlling = true
    @ObservationIgnored private var isSuspended = false
    /// Bumped by `suspend()`. An update started under an older generation stops at its next `await`.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let commander: any FanCommanding

    public init(commander: any FanCommanding) {
        self.commander = commander
    }

    public func update(settings: CoolingSettings, snapshot: HardwareSnapshot) async {
        guard !isSuspended, !snapshot.fans.isEmpty else { return }
        let started = generation

        let decision = planner.decide(settings: settings, snapshot: snapshot)
        isCriticallyHot = planner.isInEmergency || planner.isUnderCriticalPressure

        switch decision {
        case .system(let reason):
            curveTemperature = nil
            guard await returnToSystem(), generation == started else { return }
            state = switch reason {
            case .userChoice: .system
            case .noData: .noData
            }

        case .manual(let speed, let temperature):
            await drive(speed: speed, temperature: temperature, fans: snapshot.fans, state: .controlling(speed: speed), started: started)

        case .emergency:
            await drive(speed: 1, temperature: nil, fans: snapshot.fans, state: .emergency, started: started)
        }
    }

    /// Writes `speed` to every fan, then settles in `controlled`. Shared by `.manual` and `.emergency`
    /// so both obey the same helper, limits, restore-obligation, generation and failed-write rules.
    private func drive(speed: Double, temperature: Double?, fans: [FanStatus], state controlled: State, started: Int) async {
        curveTemperature = temperature
        guard commander.isReady else {
            state = .needsHelper
            return
        }
        guard fans.allSatisfy(\.hasKnownLimits) else {
            state = .failed("This Mac didn't report its fans' speed limits")
            await returnToSystem()
            return
        }
        mayBeControlling = true
        do {
            // Sent every tick even when unchanged: it doubles as the helper's heartbeat.
            for fan in fans {
                try await commander.setTarget(rpm: fan.rpm(forSpeed: speed), fanIndex: fan.index)
                guard generation == started else { return }
            }
            state = controlled
        } catch {
            guard generation == started else { return }
            state = .failed(error.localizedDescription)
            // A write may have failed halfway, leaving some fans manual.
            await returnToSystem(keepingState: true)
        }
    }

    /// Before sleep: give the fans back and stop until `resume()`.
    public func suspend() async {
        isSuspended = true
        generation += 1
        if await returnToSystem() {
            state = .system
        }
    }

    public func resume() {
        isSuspended = false
    }

    /// On quit. Synchronous because the process is about to exit.
    public func shutdown() {
        isSuspended = true
        generation += 1
        if mayBeControlling, commander.isReady {
            commander.restoreSystemControlBlocking()
        }
    }

    /// `true` once macOS confirmably has the fans, or MacFan can't have taken them.
    /// On failure the state becomes `.failed` (unless `keepingState`) and the obligation to
    /// restore remains, so the next tick tries again.
    @discardableResult
    private func returnToSystem(keepingState: Bool = false) async -> Bool {
        guard mayBeControlling else { return true }
        // Without the helper MacFan can't have written anything this session. Keep the
        // obligation so a leftover manual state is cleared once the helper is ready.
        guard commander.isReady else { return true }
        do {
            try await commander.restoreSystemControl()
            mayBeControlling = false
            return true
        } catch {
            if !keepingState {
                state = .failed("Couldn't give the fans back to macOS")
            }
            return false
        }
    }
}
