import Foundation

public enum CoolingDecision: Hashable, Sendable {
    public enum Reason: Hashable, Sendable {
        /// The user picked Automatic.
        case userChoice
        /// A part is critically hot; macOS's own controller is the safest place to be.
        case emergency
        /// The curve's temperature source isn't reporting.
        case noData
    }

    /// Fans belong to macOS.
    case system(Reason)
    /// Run every fan at `speed` (0…1 of its range). `temperature` is what the curve read, if any.
    case manual(speed: Double, temperature: Double?)
}

/// Decides, once per tick, what the fans should do. Pure logic: no I/O, fully testable.
///
/// Missing data is never read as good news: without readings from sensors that can trigger an emergency
/// an emergency stays an emergency, and Fixed Speed and Smart Curve hand the fans back.
public struct CoolingPlanner: Sendable {
    public private(set) var isInEmergency = false
    private var governor = SpeedGovernor()
    /// Every category that has reported so far, to tell "this Mac has no GPU sensor" apart
    /// from "the GPU sensor stopped reporting".
    private var observedCategories: Set<SensorCategory> = []

    public init() {}

    public mutating func decide(settings: CoolingSettings, snapshot: HardwareSnapshot) -> CoolingDecision {
        let safetyReadings = snapshot.readings.filter { $0.sensor.isIdentified && $0.sensor.category.triggersEmergency }
        let hasSafetyData = !safetyReadings.isEmpty
        if hasSafetyData {
            // Only valid readings can prove an emergency is over.
            isInEmergency = SafetyPolicy.isEmergency(safetyReadings, wasInEmergency: isInEmergency)
        }
        let previouslyObserved = observedCategories
        observedCategories.formUnion(snapshot.readings.filter(\.sensor.isIdentified).map(\.sensor.category))

        if settings.mode == .automatic {
            governor.reset()
            return .system(.userChoice)
        }
        // Max is already the strongest cooling there is, so it never needs rescuing.
        if isInEmergency, settings.mode != .max {
            governor.reset()
            return .system(.emergency)
        }

        switch settings.mode {
        case .automatic:
            return .system(.userChoice)

        case .max:
            // Needs no data: there's nothing stronger to fall back to.
            return .manual(speed: 1, temperature: nil)

        case .fixed:
            guard hasSafetyData else { return .system(.noData) }
            return .manual(speed: settings.fixedSpeed.clamped(to: 0...1), temperature: nil)

        case .curve:
            guard hasSafetyData,
                  let temperature = settings.source.temperature(in: snapshot, previouslyObserved: previouslyObserved)
            else {
                governor.reset()
                return .system(.noData)
            }
            let target = settings.activeCurve.speed(at: temperature)
            let speed = governor.next(target: target, at: snapshot.date)
            return .manual(speed: speed, temperature: temperature)
        }
    }
}

/// Smooths curve output so fans don't hunt up and down with every reading.
///
/// - Speeding up is immediate: when it gets hotter, cooling must not lag.
/// - Slowing down is gradual (`maximumDecreasePerSecond`), which also sounds calmer.
/// - Changes smaller than `deadband` are ignored.
public struct SpeedGovernor: Sendable {
    public var maximumDecreasePerSecond = 0.04
    public var deadband = 0.02

    private var current: Double?
    private var lastUpdate: Date?

    public init() {}

    public mutating func next(target: Double, at now: Date) -> Double {
        defer { lastUpdate = now }
        guard let current, let lastUpdate else {
            self.current = target
            return target
        }

        let elapsed = max(0, now.timeIntervalSince(lastUpdate))
        let value: Double
        if target > current {
            value = target
        } else if current - target <= deadband {
            value = current
        } else {
            value = max(target, current - maximumDecreasePerSecond * elapsed)
        }
        self.current = value
        return value
    }

    public mutating func reset() {
        current = nil
        lastUpdate = nil
    }
}

/// When to stop experimenting and let macOS take over.
public enum SafetyPolicy {
    /// Once in an emergency, stay there until temperatures fall this far below critical.
    public static let recoveryMargin = 5.0

    public static func isEmergency(_ readings: [SensorReading], wasInEmergency: Bool) -> Bool {
        readings.contains { reading in
            let category = reading.sensor.category
            guard reading.sensor.isIdentified, category.triggersEmergency else { return false }
            let limit = category.thresholds.critical - (wasInEmergency ? recoveryMargin : 0)
            return reading.celsius >= limit
        }
    }
}
