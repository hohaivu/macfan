import CPrivateIOKit
import Foundation
import SMCKit

/// A source of temperature sensors. Providers are not thread-safe; `HardwareMonitor` owns them.
protocol SensorProvider {
    /// Finds sensors that currently report plausible values. Relatively expensive.
    func discover() -> [Sensor]
    /// Reads the given sensors (only those belonging to this provider).
    func read(_ sensors: [Sensor]) -> [SensorReading]
}

// MARK: - SMC

final class SMCSensorProvider: SensorProvider {
    private let smc: SMCConnection
    private let chipFamily = ChipReader.brand().flatMap(SensorCatalog.chipFamily)

    init(smc: SMCConnection) {
        self.smc = smc
    }

    func discover() -> [Sensor] {
        let keys = (try? smc.allKeys()) ?? SensorCatalog.wellKnownSMCKeys.compactMap(SMCKey.init)

        let rawKeys = keys
            .filter { $0.name.hasPrefix("T") }
            .filter { key in
                guard let info = try? smc.info(for: key), SensorCatalog.isTemperatureType(info.dataType),
                      let value = smc.double(key)
                else { return false }
                return SensorCatalog.isPlausible(celsius: value)
            }
            .map(\.name)
        let found = zip(rawKeys, SensorCatalog.classify(smcKeys: rawKeys, chipFamily: chipFamily))
            .map { (key: $0, classification: $1) }
            .sorted { $0.key < $1.key }

        let names = SensorNaming.resolve(found.map(\.classification.nameTemplate))
        return zip(found, names).map { item, name in
            Sensor(
                id: "smc.\(item.key)",
                name: name,
                category: item.classification.category,
                source: .smc,
                rawKey: item.key,
                isIdentified: item.classification.isIdentified
            )
        }
    }

    func read(_ sensors: [Sensor]) -> [SensorReading] {
        sensors.compactMap { sensor in
            guard let key = SMCKey(sensor.rawKey), let value = smc.double(key),
                  SensorCatalog.isPlausible(celsius: value)
            else { return nil }
            return SensorReading(sensor: sensor, celsius: value)
        }
    }
}

// MARK: - HID (Apple Silicon)

final class HIDSensorProvider: SensorProvider {
    private let client: CPKHIDEventSystemClient?
    private var services: [String: CPKHIDServiceClient] = [:]

    init() {
        client = CPKHIDEventSystemClientCreate(kCFAllocatorDefault)
        if let client {
            // Vendor usage page 0xff00, usage 5: temperature sensors.
            let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
            _ = CPKHIDEventSystemClientSetMatching(client, matching)
        }
    }

    func discover() -> [Sensor] {
        guard let client, let array = CPKHIDEventSystemClientCopyServices(client) else { return [] }

        var found: [(id: String, product: String, classification: SensorCatalog.Classification, service: CPKHIDServiceClient)] = []
        var idCounts: [String: Int] = [:]
        for service in array as [AnyObject] {
            guard let product = CPKHIDServiceClientCopyProperty(service, "Product" as CFString) as? String,
                  let classification = SensorCatalog.classify(hidProduct: product),
                  let value = temperature(of: service), SensorCatalog.isPlausible(celsius: value)
            else { continue }

            let count = idCounts[product, default: 0]
            idCounts[product] = count + 1
            let id = count == 0 ? "hid.\(product)" : "hid.\(product)#\(count)"
            found.append((id, product, classification, service))
        }
        found.sort { $0.id < $1.id }

        services = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0.service) })
        let names = SensorNaming.resolve(found.map(\.classification.nameTemplate))
        return zip(found, names).map { item, name in
            Sensor(
                id: item.id,
                name: name,
                category: item.classification.category,
                source: .hid,
                rawKey: item.product,
                isIdentified: item.classification.isIdentified
            )
        }
    }

    func read(_ sensors: [Sensor]) -> [SensorReading] {
        sensors.compactMap { sensor in
            guard let service = services[sensor.id], let value = temperature(of: service),
                  SensorCatalog.isPlausible(celsius: value)
            else { return nil }
            return SensorReading(sensor: sensor, celsius: value)
        }
    }

    private func temperature(of service: CPKHIDServiceClient) -> Double? {
        guard let event = CPKHIDServiceClientCopyEvent(service, CPKHIDEventTypeTemperature, 0, 0) else { return nil }
        let field = Int32(CPKHIDEventTypeTemperature << 16)
        return CPKHIDEventGetFloatValue(event, field)
    }
}

// MARK: - Composite

/// Merges providers. SMC is preferred; HID sensors only fill categories SMC doesn't cover
/// (on Apple Silicon that's typically the SSD), so the same part isn't listed twice.
final class CompositeSensorProvider: SensorProvider {
    private let smc: SMCSensorProvider?
    private let hid: HIDSensorProvider

    init(smc: SMCConnection?) {
        self.smc = smc.map(SMCSensorProvider.init)
        self.hid = HIDSensorProvider()
    }

    func discover() -> [Sensor] {
        let smcSensors = smc?.discover() ?? []
        let covered = Set(smcSensors.filter(\.isIdentified).map(\.category))
        let hidSensors = hid.discover().filter { !covered.contains($0.category) }
        return smcSensors + hidSensors
    }

    func read(_ sensors: [Sensor]) -> [SensorReading] {
        let smcReadings = smc?.read(sensors.filter { $0.source == .smc }) ?? []
        let hidReadings = hid.read(sensors.filter { $0.source == .hid })
        return smcReadings + hidReadings
    }
}
