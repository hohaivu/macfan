import Foundation

/// The four ways MacFan can drive the fans.
public enum CoolingMode: String, Codable, CaseIterable, Sendable {
    /// macOS controls the fans. The default, and where MacFan always returns to.
    case automatic
    /// Speed follows a temperature curve.
    case curve
    /// One constant speed.
    case fixed
    /// Every fan at its maximum.
    case max

    public var requiresHelper: Bool { self != .automatic }
}

/// Which temperature a curve reacts to.
public enum TemperatureSource: Hashable, Codable, Sendable {
    case hottestCPU
    case hottestGPU
    case hottestOverall
    case sensor(id: String)

    /// Resolves to a temperature. CPU/GPU fall back to the overall hottest when this Mac
    /// has no such sensor at all — but not when one that used to report has gone quiet
    /// (it's in `previouslyObserved`), because silently following a cooler part would
    /// under-cool the one that matters.
    public func temperature(in snapshot: HardwareSnapshot, previouslyObserved: Set<SensorCategory> = []) -> Double? {
        switch self {
        case .hottestCPU:
            hottest(.cpu, in: snapshot, previouslyObserved: previouslyObserved)
        case .hottestGPU:
            hottest(.gpu, in: snapshot, previouslyObserved: previouslyObserved)
        case .hottestOverall:
            snapshot.hottest()?.celsius
        case .sensor(let id):
            snapshot.reading(id: id)?.celsius
        }
    }

    private func hottest(_ category: SensorCategory, in snapshot: HardwareSnapshot, previouslyObserved: Set<SensorCategory>) -> Double? {
        if let reading = snapshot.hottest(in: [category]) { return reading.celsius }
        return previouslyObserved.contains(category) ? nil : snapshot.hottest()?.celsius
    }
}

/// Everything the user chose about cooling. Switching mode keeps the others' settings.
public struct CoolingSettings: Hashable, Codable, Sendable {
    public var mode: CoolingMode = .automatic
    public var preset: CurvePreset = .balanced
    public var customCurve: FanCurve = CurvePreset.balanced.curve!
    public var source: TemperatureSource = .hottestCPU
    /// 0…1, used by `.fixed`.
    public var fixedSpeed: Double = 0.5
    /// Opt-in, risky: during an emergency Fixed and Curve keep their normal control (with its minimum speeds) instead of full speed.
    public var keepsSettingInEmergency = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case mode, preset, customCurve, source, fixedSpeed, keepsSettingInEmergency
    }

    /// Decoding validates like the UI does, so corrupt settings fall back to defaults
    /// instead of driving the fans.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(CoolingMode.self, forKey: .mode)
        preset = try container.decode(CurvePreset.self, forKey: .preset)
        customCurve = try container.decode(FanCurve.self, forKey: .customCurve)
        source = try container.decode(TemperatureSource.self, forKey: .source)
        fixedSpeed = try container.decode(Double.self, forKey: .fixedSpeed)
        keepsSettingInEmergency = try container.decodeIfPresent(Bool.self, forKey: .keepsSettingInEmergency) ?? false
        guard fixedSpeed.isFinite, (0...1).contains(fixedSpeed) else {
            throw DecodingError.dataCorruptedError(
                forKey: .fixedSpeed, in: container, debugDescription: "Fixed speed \(fixedSpeed) is outside 0…1"
            )
        }
    }

    public var activeCurve: FanCurve {
        preset.curve ?? customCurve
    }
}
