import Foundation
@testable import MacFanCore

enum Fixtures {
    static func reading(_ celsius: Double, category: SensorCategory = .cpu, id: String? = nil, identified: Bool = true) -> SensorReading {
        let id = id ?? "test.\(category.rawValue).\(celsius)"
        let sensor = Sensor(id: id, name: id, category: category, source: .smc, rawKey: "TEST", isIdentified: identified)
        return SensorReading(sensor: sensor, celsius: celsius)
    }

    static func fan(index: Int = 0, current: Double = 2000, minimum: Double = 1200, maximum: Double = 6000) -> FanStatus {
        FanStatus(index: index, name: "Fan", currentRPM: current, minimumRPM: minimum, maximumRPM: maximum, targetRPM: nil, isManual: false)
    }

    static func snapshot(_ readings: [SensorReading], at date: Date = Date(timeIntervalSince1970: 0), fans: [FanStatus] = [fan()], thermalState: ProcessInfo.ThermalState = .nominal) -> HardwareSnapshot {
        HardwareSnapshot(date: date, readings: readings, fans: fans, battery: nil, thermalState: thermalState)
    }
}
