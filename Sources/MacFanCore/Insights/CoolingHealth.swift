import Foundation

/// Who was choosing fan speeds. Temperatures under one controller can't be compared with
/// another's, so Cooling Health learns each separately.
public enum CoolingController: Hashable, Sendable {
    /// macOS's own fan control.
    case macOS
    /// MacFan's Smart Curve. Any change to the curve or what it follows is a new controller.
    case curve(FanCurve, source: TemperatureSource)

    /// Stable across launches, for storing with the log.
    var key: String {
        switch self {
        case .macOS:
            "macOS"
        case .curve(let curve, let source):
            "curve|\(source.key)|" + curve.points.map { "\($0.temperature):\($0.speed)" }.joined(separator: ",")
        }
    }
}

private extension TemperatureSource {
    var key: String {
        switch self {
        case .hottestCPU: "cpu"
        case .hottestGPU: "gpu"
        case .hottestOverall: "all"
        case .sensor(let id): "sensor:\(id)"
        }
    }
}

extension CoolingSettings {
    /// What Cooling Health learns under while MacFan drives the fans in this mode; `nil` for
    /// Fixed Speed and Max, which don't react to temperature and so reveal nothing.
    public var learningController: CoolingController? {
        switch mode {
        case .automatic: .macOS
        case .curve: .curve(activeCurve, source: source)
        case .fixed, .max: nil
        }
    }
}

/// How hard the Mac had to work to stay cool under one steady workload, for one minute.
public struct CoolingSample: Hashable, Sendable {
    public let date: Date
    /// System watts, or the whole Mac's CPU share (0…100) on Macs without a power sensor.
    public let load: Double
    /// Hottest CPU minus the coolest air or surface sensor, so the room's temperature
    /// matters less. Without such a sensor, the CPU's own temperature.
    public let rise: Double
    /// Average across fans; `nil` on Macs without fans.
    public let fanRPM: Double?
    public let controller: CoolingController

    public init(date: Date, load: Double, rise: Double, fanRPM: Double?, controller: CoolingController = .macOS) {
        self.date = date
        self.load = load
        self.rise = rise
        self.fanRPM = fanRPM
        self.controller = controller
    }
}

/// Collects `CoolingSample`s from snapshots: one per minute, and only from minutes worth
/// comparing over weeks. A minute is skipped when its average workload differs a lot from
/// the minute before, when nobody comparable was driving the fans (Fixed Speed, Max, or
/// another app), or soon after the Mac woke, MacFan started or the controller changed.
///
/// Steadiness is judged minute to minute, not within the minute: power on Apple Silicon
/// jumps around from second to second, but chips heat up over tens of seconds, so what
/// matters is that the average stayed put.
public struct CoolingSampler: Sendable {
    public static let window: TimeInterval = 60
    /// Temperatures need a few minutes to settle after a wake or a launch.
    public static let settleTime: TimeInterval = 300
    /// A gap in readings longer than this is treated as the Mac having slept.
    public static let maximumGap: TimeInterval = 30

    private var settledFrom: Date?
    private var lastUpdate: Date?
    private var windowStart: Date?
    private var window = Window()
    private var previousLoad: Double?
    private var controller: CoolingController?

    /// Running totals for the current minute, so a refresh costs a few additions.
    private struct Window: Sendable {
        var count = 0
        var loadSum = 0.0
        var riseSum = 0.0
        var rpmSum = 0.0
        var rpmCount = 0
        var isValid = true
    }

    public init() {}

    /// `load` is the same measure as `CoolingSample.load`; `controller` is who chose the fan
    /// speeds, or `nil` when it's nobody worth learning from.
    public mutating func add(_ snapshot: HardwareSnapshot, load: Double?, controller: CoolingController?) -> CoolingSample? {
        let date = snapshot.date
        if let lastUpdate, date.timeIntervalSince(lastUpdate) <= Self.maximumGap, controller == self.controller {
            // Readings are continuous, under the same controller.
        } else {
            // After a gap or a change of controller, fans and temperatures take a while to settle.
            self.controller = controller
            settledFrom = date.addingTimeInterval(Self.settleTime)
            previousLoad = nil
            resetWindow(at: date)
        }
        lastUpdate = date

        guard let settledFrom, date >= settledFrom else { return nil }
        if windowStart == nil { resetWindow(at: date) }

        // Under macOS, a manual fan means another app has taken over.
        let isComparable = switch controller {
        case .macOS: !snapshot.fans.contains(where: \.isManual)
        case .curve: true
        case nil: false
        }
        if let load, let rise = Self.rise(in: snapshot), isComparable {
            window.count += 1
            window.loadSum += load
            window.riseSum += rise
            if !snapshot.fans.isEmpty {
                window.rpmSum += snapshot.fans.map(\.currentRPM).reduce(0, +) / Double(snapshot.fans.count)
                window.rpmCount += 1
            }
        } else {
            window.isValid = false
        }

        guard let windowStart, date.timeIntervalSince(windowStart) >= Self.window else { return nil }
        defer { resetWindow(at: date) }
        guard window.isValid, window.count >= 3, let controller else {
            previousLoad = nil
            return nil
        }
        let meanLoad = window.loadSum / Double(window.count)
        defer { previousLoad = meanLoad }
        // Steady: within 20% (or 1 unit, for light loads) of the minute before.
        guard let previousLoad, abs(meanLoad - previousLoad) <= max(meanLoad * 0.2, 1) else { return nil }
        return CoolingSample(
            date: date,
            load: meanLoad,
            rise: window.riseSum / Double(window.count),
            fanRPM: window.rpmCount > 0 ? window.rpmSum / Double(window.rpmCount) : nil,
            controller: controller
        )
    }

    private mutating func resetWindow(at date: Date) {
        windowStart = date
        window = Window()
    }

    /// Hottest CPU reading above the coolest air or surface reading.
    static func rise(in snapshot: HardwareSnapshot) -> Double? {
        guard let cpu = snapshot.hottest(in: [.cpu])?.celsius else { return nil }
        let air = snapshot.readings.filter { $0.sensor.isAirReference }.map(\.celsius).min()
        return air.map { cpu - $0 } ?? cpu
    }
}

extension Sensor {
    /// Air and surface sensors that follow the room more than the chips: ambient, airflow and
    /// palm rest. Heat pipes, Thunderbolt and display sensors are left out.
    public var isAirReference: Bool {
        category == .enclosure && ["TA", "Ta", "Ts"].contains { rawKey.hasPrefix($0) }
    }
}

/// The whole Mac's CPU share between successive load readings, for Macs without a power sensor.
public struct CPUShareMeter: Sendable {
    private var previous: CPULoad?

    public init() {}

    /// 0…100, or `nil` on the first reading.
    public mutating func update(_ load: CPULoad) -> Double? {
        defer { previous = load }
        guard let previous, load.totalTicks > previous.totalTicks, load.busyTicks >= previous.busyTicks else { return nil }
        return Double(load.busyTicks - previous.busyTicks) / Double(load.totalTicks - previous.totalTicks) * 100
    }
}

/// Weeks of `CoolingSample`s, condensed to one entry per day, workload band and controller.
public struct CoolingLog: Codable, Hashable, Sendable {
    public enum LoadKind: String, Codable, Sendable {
        case watts
        case cpuShare
    }

    /// Averages for one day, one band of workload and one controller.
    public struct Entry: Codable, Hashable, Sendable {
        /// Midnight of the day, local time.
        public let day: Date
        /// Lower edge of the band, in `loadKind` units.
        public let band: Int
        /// `CoolingController.key`.
        public let controller: String
        public var minutes: Int
        public var riseTotal: Double
        public var rpmTotal: Double
        public var rpmMinutes: Int

        public var averageRise: Double { riseTotal / Double(max(minutes, 1)) }
        public var averageRPM: Double? { rpmMinutes > 0 ? rpmTotal / Double(rpmMinutes) : nil }

        init(day: Date, band: Int, controller: String, minutes: Int, riseTotal: Double, rpmTotal: Double, rpmMinutes: Int) {
            self.day = day
            self.band = band
            self.controller = controller
            self.minutes = minutes
            self.riseTotal = riseTotal
            self.rpmTotal = rpmTotal
            self.rpmMinutes = rpmMinutes
        }

        private enum CodingKeys: String, CodingKey {
            case day, band, controller, minutes, riseTotal, rpmTotal, rpmMinutes
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            day = try container.decode(Date.self, forKey: .day)
            band = try container.decode(Int.self, forKey: .band)
            // Logs from before Smart Curve was learned from only ever held macOS's minutes.
            controller = try container.decodeIfPresent(String.self, forKey: .controller) ?? CoolingController.macOS.key
            minutes = try container.decode(Int.self, forKey: .minutes)
            riseTotal = try container.decode(Double.self, forKey: .riseTotal)
            rpmTotal = try container.decode(Double.self, forKey: .rpmTotal)
            rpmMinutes = try container.decode(Int.self, forKey: .rpmMinutes)
        }
    }

    public static let retentionDays = 120
    /// The comparison needs this many days with data before it means anything.
    public static let learningDays = 14

    /// Version 2: `rise` is measured on CPU cores. A missing version counts as 1 (0.3.x).
    private static let currentMeasureVersion = 2

    public private(set) var loadKind: LoadKind?
    public private(set) var entries: [Entry] = []

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case loadKind, entries, measureVersion
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Rises measured on another basis can't be compared, so start learning over.
        guard try container.decodeIfPresent(Int.self, forKey: .measureVersion) ?? 1 == Self.currentMeasureVersion else { return }
        loadKind = try container.decodeIfPresent(LoadKind.self, forKey: .loadKind)
        entries = try container.decode([Entry].self, forKey: .entries)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentMeasureVersion, forKey: .measureVersion)
        try container.encodeIfPresent(loadKind, forKey: .loadKind)
        try container.encode(entries, forKey: .entries)
    }

    public static func bandWidth(for kind: LoadKind) -> Double {
        switch kind {
        case .watts: 5
        case .cpuShare: 10
        }
    }

    public mutating func add(_ sample: CoolingSample, kind: LoadKind, calendar: Calendar = .current) {
        // Watts and CPU shares can't be compared; a Mac only ever reports one of them, but be safe.
        if loadKind != kind {
            loadKind = kind
            entries = []
        }
        let day = calendar.startOfDay(for: sample.date)
        let band = Int((sample.load / Self.bandWidth(for: kind)).rounded(.down))
        let controller = sample.controller.key
        if let index = entries.firstIndex(where: { $0.day == day && $0.band == band && $0.controller == controller }) {
            entries[index].minutes += 1
            entries[index].riseTotal += sample.rise
            if let rpm = sample.fanRPM {
                entries[index].rpmTotal += rpm
                entries[index].rpmMinutes += 1
            }
        } else {
            entries.append(Entry(day: day, band: band, controller: controller, minutes: 1, riseTotal: sample.rise,
                                 rpmTotal: sample.fanRPM ?? 0, rpmMinutes: sample.fanRPM == nil ? 0 : 1))
        }
        let cutoff = calendar.date(byAdding: .day, value: -Self.retentionDays, to: day) ?? day
        entries.removeAll { $0.day < cutoff }
    }

    /// Distinct days with at least `minimumMinutes` of usable data under `controller`.
    public func daysCollected(under controller: CoolingController, minimumMinutes: Int = 10) -> Int {
        let key = controller.key
        return Dictionary(grouping: entries.filter { $0.controller == key }, by: \.day)
            .filter { $0.value.map(\.minutes).reduce(0, +) >= minimumMinutes }
            .count
    }

    /// Whether some Smart Curve other than `controller` has data: a sign the curve was changed
    /// and learning started over.
    public func hasLearnedOtherCurve(than controller: CoolingController) -> Bool {
        let key = controller.key
        return entries.contains { $0.controller != key && $0.controller != CoolingController.macOS.key }
    }
}
