import Foundation
import IOKit
import SMCKit

/// Reads sensors, fans and battery. Everything here is read-only and needs no privileges.
///
/// An actor rather than main-actor code because sensor discovery enumerates thousands of
/// SMC keys (~0.5 s), which would hang the UI, and because it owns non-`Sendable`
/// providers that must only ever be touched from one place.
public actor HardwareMonitor {
    /// Health changes slowly, but charge rate and time left are live numbers. A full
    /// IORegistry read takes about 0.3 ms on an M1 Pro, so every few seconds costs nothing.
    private static let batteryRefreshInterval: TimeInterval = 5

    /// Total system power. Apple Silicon and some Intel Macs publish it; others don't have the key.
    private static let systemPowerKey: SMCKey = "PSTR"

    private let smc: SMCConnection?
    private let sensorProvider: CompositeSensorProvider
    private let fanControl: SMCFanControl<SMCConnection>?
    private var sensors: [Sensor]?
    private var battery: (date: Date, info: BatteryInfo?)?

    public init() {
        let smc = try? SMCConnection()
        self.smc = smc
        sensorProvider = CompositeSensorProvider(smc: smc)
        fanControl = smc.map { SMCFanControl(smc: $0) }
    }

    /// `false` in virtual machines and other environments without an SMC.
    public var hasSMC: Bool { fanControl != nil }

    public func snapshot(at date: Date = Date()) -> HardwareSnapshot {
        let sensors = self.sensors ?? discover()
        return HardwareSnapshot(
            date: date,
            readings: sensorProvider.read(sensors),
            fans: readFans(),
            battery: readBattery(at: date),
            systemPower: readSystemPower(),
            thermalState: ProcessInfo.processInfo.thermalState
        )
    }

    /// Forgets known sensors and searches again, e.g. after an external drive is attached.
    @discardableResult
    public func discover() -> [Sensor] {
        let found = sensorProvider.discover()
        sensors = found
        return found
    }

    private func readFans() -> [FanStatus] {
        guard let readings = try? fanControl?.readings() else { return [] }
        return readings.map { reading in
            // Unknown limits are shown as best-effort numbers but flagged, so MacFan never
            // takes manual control of a fan whose safe range it doesn't know.
            let limits = reading.validLimits
            return FanStatus(
                index: reading.index,
                name: FanStatus.name(forIndex: reading.index, count: readings.count),
                currentRPM: reading.actualRPM,
                minimumRPM: limits?.lowerBound ?? 0,
                maximumRPM: limits?.upperBound ?? reading.actualRPM,
                targetRPM: reading.targetRPM,
                isManual: reading.isManual,
                hasKnownLimits: limits != nil
            )
        }
    }

    /// Re-reads the battery on the next snapshot, e.g. right after the power source changed.
    public func invalidateBattery() {
        battery = nil
    }

    private func readSystemPower() -> Double? {
        guard let watts = smc?.double(Self.systemPowerKey), watts.isFinite, watts > 0, watts < 1000 else { return nil }
        return watts
    }

    private func readBattery(at date: Date) -> BatteryInfo? {
        if let battery, date.timeIntervalSince(battery.date) < Self.batteryRefreshInterval {
            return battery.info
        }
        let info = BatteryReader.read()
        battery = (date, info)
        return info
    }
}

public enum BatteryReader {
    /// `nil` on Macs without a battery.
    public static func read() -> BatteryInfo? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any]
        else { return nil }
        return BatteryInfo(properties: dictionary)
    }
}

public enum ChipReader {
    /// `machdep.cpu.brand_string`, e.g. "Apple M4 Pro".
    public static func brand() -> String? {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
