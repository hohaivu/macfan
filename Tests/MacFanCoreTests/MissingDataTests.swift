import Foundation
import Testing
@testable import MacFanCore

/// R4: losing temperature data must never be read as "it's fine now".
@Suite("Missing temperature data")
struct MissingDataTests {
    let critical = SensorCategory.cpu.thresholds.critical

    func settings(_ mode: CoolingMode) -> CoolingSettings {
        var settings = CoolingSettings()
        settings.mode = mode
        settings.fixedSpeed = 0
        return settings
    }

    @Test func `an emergency doesn't end when the sensors go quiet`() {
        var planner = CoolingPlanner()
        _ = planner.decide(settings: settings(.fixed), snapshot: Fixtures.snapshot([Fixtures.reading(critical + 1)]))

        let silent = Fixtures.snapshot([])
        #expect(planner.decide(settings: settings(.fixed), snapshot: silent) == .emergency)
        #expect(planner.isInEmergency)
    }

    /// Opt-in: with the flag on the same silent snapshot means missing data, not an emergency.
    @Test func `with the flag on, quiet sensors after an emergency are no data`() {
        var planner = CoolingPlanner()
        var keeping = settings(.fixed)
        keeping.keepsSettingInEmergency = true
        _ = planner.decide(settings: keeping, snapshot: Fixtures.snapshot([Fixtures.reading(critical + 1)]))
        #expect(planner.decide(settings: keeping, snapshot: Fixtures.snapshot([])) == .system(.noData))
        #expect(planner.isInEmergency, "the latch holds, only the decision differs")
    }

    @Test func `an emergency ends once valid readings show it cooled down`() {
        var planner = CoolingPlanner()
        _ = planner.decide(settings: settings(.fixed), snapshot: Fixtures.snapshot([Fixtures.reading(critical + 1)]))
        _ = planner.decide(settings: settings(.fixed), snapshot: Fixtures.snapshot([]))

        // 94°C is just inside the recovery margin, so the emergency ends. The floor (contract 5) gives 0.74 there.
        let cooled = Fixtures.snapshot([Fixtures.reading(critical - SafetyPolicy.recoveryMargin - 1)])
        guard case let .manual(speed, temperature) = planner.decide(settings: settings(.fixed), snapshot: cooled) else {
            Issue.record("expected the emergency to end")
            return
        }
        #expect(abs(speed - 0.74) < 1e-9)
        #expect(temperature == nil)
    }

    @Test(arguments: [CoolingMode.fixed, .curve])
    func `manual modes hand back to macOS without safety data`(mode: CoolingMode) {
        var planner = CoolingPlanner()
        #expect(planner.decide(settings: settings(mode), snapshot: Fixtures.snapshot([])) == .system(.noData))
    }

    @Test func `unidentified or irrelevant sensors are not safety data`() {
        var planner = CoolingPlanner()
        let snapshot = Fixtures.snapshot([
            Fixtures.reading(40, category: .other, identified: false),
            Fixtures.reading(40, category: .enclosure),
        ])
        #expect(planner.decide(settings: settings(.fixed), snapshot: snapshot) == .system(.noData))
    }

    @Test func `full speed keeps cooling without data`() {
        var planner = CoolingPlanner()
        #expect(planner.decide(settings: settings(.max), snapshot: Fixtures.snapshot([])) == .manual(speed: 1, temperature: nil))
    }

    @Test func `a curve won't follow a cooler sensor when the CPU stops reporting`() {
        var planner = CoolingPlanner()
        let curve = settings(.curve)
        _ = planner.decide(settings: curve, snapshot: Fixtures.snapshot([
            Fixtures.reading(80, id: "cpu"),
            Fixtures.reading(40, category: .storage, id: "ssd"),
        ]))

        let cpuGone = Fixtures.snapshot([Fixtures.reading(40, category: .storage, id: "ssd")])
        #expect(planner.decide(settings: curve, snapshot: cpuGone) == .system(.noData))
    }

    @Test func `a curve falls back when this Mac never had that sensor`() {
        var planner = CoolingPlanner()
        var curve = settings(.curve)
        curve.source = .hottestGPU
        let noGPU = Fixtures.snapshot([Fixtures.reading(60, id: "cpu")])
        #expect(planner.decide(settings: curve, snapshot: noGPU) != .system(.noData))
    }
}

/// R7: settings read from disk get the same validation as settings made in the app.
@Suite("Decoding cooling settings")
struct CoolingSettingsDecodingTests {
    func decodeCurve(_ points: [(Double, Double)]) throws -> FanCurve {
        let json = "{\"points\":[" + points.map { "{\"temperature\":\($0.0),\"speed\":\($0.1)}" }.joined(separator: ",") + "]}"
        return try JSONDecoder().decode(FanCurve.self, from: Data(json.utf8))
    }

    @Test func `a valid curve round-trips`() throws {
        let curve = try #require(CurvePreset.balanced.curve)
        let decoded = try JSONDecoder().decode(FanCurve.self, from: JSONEncoder().encode(curve))
        #expect(decoded == curve)
    }

    @Test(arguments: [
        [(40.0, 1.0), (80.0, 0.0)],             // hotter would mean slower
        [(80.0, 0.2), (40.0, 0.6)],             // out of order
        [(40.0, 0.2), (40.5, 0.6)],             // closer than the minimum gap
        [(10.0, 0.2), (80.0, 0.6)],             // outside the temperature range
        [(40.0, -0.1), (80.0, 0.6)],            // speed below 0
        [(40.0, 0.2), (80.0, 1.5)],             // speed above 1
        [(50.0, 0.5)],                          // a single point
    ])
    func `an invalid stored curve is rejected`(points: [(Double, Double)]) {
        #expect(throws: DecodingError.self) { try decodeCurve(points) }
    }

    @Test func `non-finite numbers are rejected`() {
        let json = #"{"points":[{"temperature":40,"speed":0},{"temperature":80,"speed":1e999}]}"#
        #expect(throws: (any Error).self) { try JSONDecoder().decode(FanCurve.self, from: Data(json.utf8)) }
    }

    @Test func `an invalid fixed speed is rejected`() throws {
        var settings = CoolingSettings()
        settings.fixedSpeed = 2
        let data = try JSONEncoder().encode(settings)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(CoolingSettings.self, from: data) }
    }

    @Test func `the flag keeping the setting in an emergency is off by default`() {
        #expect(CoolingSettings().keepsSettingInEmergency == false)
    }

    @Test(arguments: [false, true])
    func `the flag round-trips`(keeps: Bool) throws {
        var settings = CoolingSettings()
        settings.keepsSettingInEmergency = keeps
        let decoded = try JSONDecoder().decode(CoolingSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        #expect(decoded.keepsSettingInEmergency == keeps)
    }

    /// Settings saved by an earlier version have no flag: they decode with it off and keep every other choice.
    @Test func `settings from an earlier version decode with the flag off`() throws {
        var settings = CoolingSettings()
        settings.mode = .curve
        settings.preset = .custom
        settings.customCurve = FanCurve([(45, 0.25), (85, 0.9)])
        settings.source = .sensor(id: "smc.TC0P")
        settings.fixedSpeed = 0.37
        settings.keepsSettingInEmergency = true
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        #expect(object.removeValue(forKey: "keepsSettingInEmergency") != nil, "the encoder writes the key")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(CoolingSettings.self, from: legacy)
        var expected = settings
        expected.keepsSettingInEmergency = false
        #expect(decoded == expected)
    }

    @Test func `valid settings round-trip`() throws {
        var settings = CoolingSettings()
        settings.mode = .curve
        settings.preset = .custom
        settings.source = .sensor(id: "smc.TC0P")
        settings.fixedSpeed = 0.4
        let decoded = try JSONDecoder().decode(CoolingSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }
}
