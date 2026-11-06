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
    /// Critical thermal pressure, latched until it drops to fair. Independent of `isInEmergency`.
    public private(set) var isUnderCriticalPressure = false
    private var lastMode: CoolingMode?
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
        // Pressure comes from macOS, not the sensors, so it updates even with no readings.
        isUnderCriticalPressure = SafetyPolicy.isCriticalPressure(snapshot.thermalState, wasCritical: isUnderCriticalPressure)
        let previouslyObserved = observedCategories
        observedCategories.formUnion(snapshot.readings.filter(\.sensor.isIdentified).map(\.sensor.category))

        if settings.mode != lastMode {
            governor.reset()
            lastMode = settings.mode
        }
        if settings.mode == .automatic {
            governor.reset()
            return .system(.userChoice)
        }
        // Max is already the strongest cooling there is, so it never needs rescuing.
        if isInEmergency || isUnderCriticalPressure, settings.mode != .max {
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
            let floor = SafetyPolicy.minimumSpeed(readings: safetyReadings, thermalState: snapshot.thermalState)
            // The floor goes through the governor so it can come down through the hold and fall.
            let governedFloor = governor.next(target: floor, at: snapshot.date, urgent: true)
            return .manual(speed: max(settings.fixedSpeed.clamped(to: 0...1), governedFloor), temperature: nil)

        case .curve:
            guard hasSafetyData,
                  let temperature = settings.source.temperature(in: snapshot, previouslyObserved: previouslyObserved)
            else {
                governor.reset()
                return .system(.noData)
            }
            let floor = SafetyPolicy.minimumSpeed(readings: safetyReadings, thermalState: snapshot.thermalState)
            let target = max(settings.activeCurve.speed(at: temperature), floor)
            let speed = governor.next(target: target, at: snapshot.date, urgent: floor > 0)
            return .manual(speed: speed, temperature: temperature)
        }
    }
}

/// Paces fan speed changes so fans don't hunt up and down with every reading.
///
/// - Rises are immediate when `urgent` (protection must not lag), otherwise capped at `maximumIncreasePerSecond`.
/// - Falls wait `holdTime` after the last demand, then are gradual (`maximumDecreasePerSecond`),
///   counting only time after the hold expired. A fall never goes below the target.
/// - Falls of `deadband` or less are ignored and count as demand.
public struct SpeedGovernor: Sendable {
    public var maximumIncreasePerSecond = 0.15
    public var maximumDecreasePerSecond = 0.04
    public var deadband = 0.02
    public var holdTime: TimeInterval = 10

    private var current: Double?
    private var lastUpdate: Date?
    private var lastDemand: Date?

    public init() {}

    public mutating func next(target: Double, at now: Date, urgent: Bool = false) -> Double {
        defer { lastUpdate = now }
        guard let current, let lastUpdate else {
            self.current = target
            lastDemand = now
            return target
        }

        let elapsed = max(0, now.timeIntervalSince(lastUpdate))
        let value: Double
        if target > current {
            value = urgent ? target : min(target, current + maximumIncreasePerSecond * elapsed)
            lastDemand = now
        } else if current - target <= deadband {
            value = current
            lastDemand = now
        } else if let lastDemand, now.timeIntervalSince(lastDemand) < holdTime {
            value = current
        } else {
            // Only the time past the end of the hold counts as fall time.
            let holdEnd = (lastDemand ?? lastUpdate).addingTimeInterval(holdTime)
            let budget = max(0, now.timeIntervalSince(max(lastUpdate, holdEnd)))
            value = max(target, current - maximumDecreasePerSecond * budget)
        }
        self.current = value
        return value
    }

    public mutating func reset() {
        current = nil
        lastUpdate = nil
        lastDemand = nil
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

    /// Only the main CPU-core and GPU categories feed the floor: die, battery, storage and memory
    /// readings keep just the emergency path, so they don't make the fans loud.
    public static let floorCategories: Set<SensorCategory> = [.cpu, .gpu]
    public static let seriousPressureMinimum = 0.6
    /// Written for a critical limit of 100°C; `minimumSpeed` shifts each category onto it.
    public static let floorCurve = FanCurve([(85, 0), (90, 0.5), (95, 0.8)])

    /// The lowest speed Fixed and Curve may run at: the highest of each cpu/gpu reading's floor
    /// and the serious-pressure minimum.
    public static func minimumSpeed(readings: [SensorReading], thermalState: ProcessInfo.ThermalState) -> Double {
        let fromReadings = readings
            .filter { $0.sensor.isIdentified && floorCategories.contains($0.sensor.category) }
            .map { floorCurve.speed(at: $0.celsius - $0.sensor.category.thresholds.critical + 100) }
            .max() ?? 0
        let fromPressure = thermalState == .serious || thermalState == .critical ? seriousPressureMinimum : 0
        return max(fromReadings, fromPressure)
    }

    /// Starts at critical, stays through serious, ends at fair or nominal.
    public static func isCriticalPressure(_ state: ProcessInfo.ThermalState, wasCritical: Bool) -> Bool {
        state == .critical || (wasCritical && state == .serious)
    }

    /// Whether `curve` runs below the floor curve anywhere. Exact: both are piecewise linear and
    /// flat beyond their ends, so checking the points of both is enough.
    public static func isBelowMinimum(_ curve: FanCurve) -> Bool {
        let temperatures = Set((curve.points + floorCurve.points).map(\.temperature))
        return temperatures.contains { curve.speed(at: $0) < floorCurve.speed(at: $0) - 1e-9 }
    }
}
