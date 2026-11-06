import Foundation
import MacFanCore
import SMCKit

// `macfanctl` — inspect what MacFan sees. Useful for bug reports and for adding
// sensor names for new Macs (see docs/ADDING_SENSORS.md).

let usage = """
    usage: macfanctl <command>

      sensors [--all]   Temperatures MacFan recognises (--all includes unidentified ones)
      fans              Fan speeds and limits
      battery           Battery health
      power             System power draw and battery charge rate
      apps              Apps using the most CPU over the next two seconds
      keys              Every SMC temperature key with its type and value (for contributors)
    """

let arguments = CommandLine.arguments.dropFirst()
let monitor = HardwareMonitor()

switch arguments.first {
case "sensors":
    let showAll = arguments.contains("--all")
    let snapshot = await monitor.snapshot()
    let readings = snapshot.readings
        .filter { showAll || $0.sensor.isIdentified }
        .sorted(by: SensorReading.displayOrder)
    if readings.isEmpty { print("No sensors found.") }
    for reading in readings {
        let category = reading.sensor.category.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)
        let name = reading.sensor.name.padding(toLength: 26, withPad: " ", startingAt: 0)
        let key = reading.sensor.rawKey.padding(toLength: 18, withPad: " ", startingAt: 0)
        print("\(category) \(name) \(key) \(String(format: "%6.1f °C", reading.celsius))")
    }

case "fans":
    let snapshot = await monitor.snapshot()
    if snapshot.fans.isEmpty { print("This Mac has no fans.") }
    for fan in snapshot.fans {
        let mode = fan.isManual ? "manual" : "auto"
        print("\(fan.name): \(Int(fan.currentRPM)) rpm (min \(Int(fan.minimumRPM)), max \(Int(fan.maximumRPM)), \(mode))")
    }

case "battery":
    guard let battery = BatteryReader.read() else {
        print("No battery.")
        exit(0)
    }
    print("Health:     \(Int((battery.health * 100).rounded()))% (\(battery.condition.rawValue))")
    print("Cycles:     \(battery.cycleCount) of \(battery.ratedCycles)")
    print("Capacity:   \(battery.fullChargeCapacity) / \(battery.designCapacity) mAh")
    print("Charge:     \(Int((battery.charge * 100).rounded()))%\(battery.isCharging ? " (charging)" : "")")
    if let celsius = battery.celsius { print(String(format: "Temperature: %.1f °C", celsius)) }

case "power":
    let snapshot = await monitor.snapshot()
    if let watts = snapshot.systemPower { print(String(format: "System:     %.1f W", watts)) } else { print("System:     not reported by this Mac") }
    if let battery = snapshot.battery {
        if let watts = battery.power { print(String(format: "Battery:    %+.1f W", watts)) }
        if let adapter = battery.adapterWatts { print("Adapter:    \(adapter) W") }
        if let minutes = battery.minutesRemaining { print("Remaining:  \(minutes / 60)h \(minutes % 60)m") }
    }

case "apps":
    let activity = ActivityMonitor()
    let start = ContinuousClock.now
    _ = await activity.sample()
    let cost = ContinuousClock.now - start
    try? await Task.sleep(for: .seconds(2))
    for app in (await activity.sample() ?? []).prefix(10) {
        print(String(format: "%5.1f%% of Mac  %6.1f%% of a core  ", app.shareOfMac, app.cpuPercent) + "\(app.name)  \(app.id)")
    }
    print("(one sample took \(cost.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 2)))))")

case "keys":
    do {
        let smc = try SMCConnection()
        let keys = try smc.allKeys().filter { $0.name.hasPrefix("T") }
        let classifications = SensorCatalog.classify(
            smcKeys: keys.map(\.name), chipFamily: ChipReader.brand().flatMap(SensorCatalog.chipFamily)
        )
        for (key, classification) in zip(keys, classifications) {
            guard let info = try? smc.info(for: key), SensorCatalog.isTemperatureType(info.dataType) else { continue }
            let value = smc.double(key).map { String(format: "%7.2f", $0) } ?? "      ?"
            let label = classification.isIdentified ? classification.nameTemplate : "—"
            print("\(key.name)  \(info.dataType)  \(value)  \(label)")
        }
    } catch {
        print("Could not read the SMC: \(error)")
        exit(1)
    }

default:
    print(usage)
    exit(arguments.isEmpty ? 0 : 64)
}
