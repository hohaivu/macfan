import Foundation

/// What part of the Mac a sensor measures. Order of cases is display order.
public enum SensorCategory: String, CaseIterable, Codable, Sendable, Comparable {
    case cpu
    case cpuDie
    case gpu
    case memory
    case storage
    case battery
    case power
    case wireless
    case enclosure
    case other

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    /// Temperatures that are normal, elevated or dangerous differ a lot between parts:
    /// an Apple Silicon CPU at 90 °C under load is fine, a battery at 45 °C is not.
    public var thresholds: TemperatureThresholds {
        switch self {
        case .cpu, .cpuDie, .gpu: TemperatureThresholds(warm: 70, hot: 90, critical: 100)
        case .battery: TemperatureThresholds(warm: 35, hot: 45, critical: 55)
        case .storage: TemperatureThresholds(warm: 50, hot: 65, critical: 75)
        // Voltage regulators routinely run in the 70s and 80s.
        case .power: TemperatureThresholds(warm: 75, hot: 95, critical: 110)
        case .memory, .wireless, .enclosure, .other: TemperatureThresholds(warm: 50, hot: 70, critical: 85)
        }
    }

    /// Categories whose overheating is a reason to step in.
    public var isSafetyRelevant: Bool {
        switch self {
        case .cpu, .gpu, .memory, .storage, .battery: true
        case .cpuDie, .power, .wireless, .enclosure, .other: false
        }
    }

    /// Die sensors run hotter than the cores but are where overheating shows first, so only
    /// the emergency checks read them; every other consumer uses `isSafetyRelevant`.
    public var triggersEmergency: Bool { isSafetyRelevant || self == .cpuDie }
}

public struct Sensor: Identifiable, Hashable, Codable, Sendable {
    public enum Source: String, Codable, Sendable {
        case smc
        case hid
    }

    /// Stable across launches, e.g. `smc.TC0P` or `hid.NAND CH0 temp`.
    public let id: String
    public let name: String
    public let category: SensorCategory
    public let source: Source
    /// The SMC key or HID product name this sensor was read from.
    public let rawKey: String
    /// `false` for sensors MacFan found but has no name for. Hidden by default.
    public let isIdentified: Bool

    public init(id: String, name: String, category: SensorCategory, source: Source, rawKey: String, isIdentified: Bool) {
        self.id = id
        self.name = name
        self.category = category
        self.source = source
        self.rawKey = rawKey
        self.isIdentified = isIdentified
    }
}

public struct SensorReading: Identifiable, Hashable, Sendable {
    public let sensor: Sensor
    public let celsius: Double

    public init(sensor: Sensor, celsius: Double) {
        self.sensor = sensor
        self.celsius = celsius
    }

    public var id: String { sensor.id }
    public var level: TemperatureLevel { sensor.category.thresholds.level(for: celsius) }
}

extension SensorReading {
    /// Category first, then natural name order ("CPU 2" before "CPU 10").
    public static func displayOrder(_ lhs: SensorReading, _ rhs: SensorReading) -> Bool {
        if lhs.sensor.category != rhs.sensor.category {
            return lhs.sensor.category < rhs.sensor.category
        }
        return lhs.sensor.name.localizedStandardCompare(rhs.sensor.name) == .orderedAscending
    }
}
