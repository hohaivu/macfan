import Foundation

/// Everything MacFan knows about the hardware at one moment.
public struct HardwareSnapshot: Sendable {
    public var date: Date
    public var readings: [SensorReading]
    public var fans: [FanStatus]
    public var battery: BatteryInfo?
    /// Whole-system power draw in watts, where the SMC reports it (Apple Silicon).
    public var systemPower: Double?
    /// macOS's own view of thermal pressure; it sees throttling the sensors miss.
    public var thermalState: ProcessInfo.ThermalState

    public init(
        date: Date,
        readings: [SensorReading],
        fans: [FanStatus],
        battery: BatteryInfo?,
        systemPower: Double? = nil,
        thermalState: ProcessInfo.ThermalState = .nominal
    ) {
        self.date = date
        self.readings = readings
        self.fans = fans
        self.battery = battery
        self.systemPower = systemPower
        self.thermalState = thermalState
    }

    public static let empty = HardwareSnapshot(date: .distantPast, readings: [], fans: [], battery: nil)

    public func reading(id: String) -> SensorReading? {
        readings.first { $0.id == id }
    }

    /// Hottest identified reading, optionally restricted to some categories.
    public func hottest(in categories: Set<SensorCategory>? = nil) -> SensorReading? {
        readings
            .filter { $0.sensor.isIdentified && (categories?.contains($0.sensor.category) ?? true) }
            .max { $0.celsius < $1.celsius }
    }

    /// One summary per category, in display order.
    public func summaries(includeUnidentified: Bool = false) -> [CategorySummary] {
        let visible = readings.filter { includeUnidentified || $0.sensor.isIdentified }
        return Dictionary(grouping: visible, by: \.sensor.category)
            .compactMap { CategorySummary(category: $0.key, readings: $0.value) }
            .sorted { $0.category < $1.category }
    }

    /// The most concerning level across safety-relevant sensors.
    public var worstLevel: TemperatureLevel {
        readings
            .filter { $0.sensor.isIdentified && $0.sensor.category.isSafetyRelevant }
            .map(\.level)
            .max() ?? .cool
    }
}

public struct CategorySummary: Identifiable, Hashable, Sendable {
    public let category: SensorCategory
    public let hottest: SensorReading
    public let average: Double
    public let count: Int

    public init?(category: SensorCategory, readings: [SensorReading]) {
        guard let hottest = readings.max(by: { $0.celsius < $1.celsius }) else { return nil }
        self.category = category
        self.hottest = hottest
        self.average = readings.map(\.celsius).reduce(0, +) / Double(readings.count)
        self.count = readings.count
    }

    public var id: SensorCategory { category }
    public var level: TemperatureLevel { hottest.level }
}
