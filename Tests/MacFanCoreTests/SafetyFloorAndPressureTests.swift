import Foundation
import Testing
@testable import MacFanCore

/// Tests for docs/specs/fan-control.md: safety floor, thermal pressure and pacing in `CoolingPlanner`.
/// Dates are fixed offsets, so nothing here sleeps or reads the clock.
private enum Sample {
    static func at(_ seconds: Double, cpu: Double? = nil, _ state: ProcessInfo.ThermalState = .nominal) -> HardwareSnapshot {
        Fixtures.snapshot(cpu.map { [Fixtures.reading($0)] } ?? [], at: Date(timeIntervalSince1970: seconds), thermalState: state)
    }

    /// Fixed mode at `fixed`, or Curve mode on a flat custom curve at `curve`.
    static func settings(_ mode: CoolingMode, fixed: Double = 0.2, curve: Double = 0.3) -> CoolingSettings {
        var settings = CoolingSettings()
        settings.mode = mode
        settings.fixedSpeed = fixed
        settings.preset = .custom
        settings.customCurve = FanCurve([(40, curve), (80, curve)])
        return settings
    }

    static func speed(_ decision: CoolingDecision) -> Double? {
        if case let .manual(speed, _) = decision { speed } else { nil }
    }
}

@Suite("Safety floor values")
struct SafetyFloorValueTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let category: SensorCategory
        let celsius: Double
        let expected: Double
        var identified = true
        var testDescription: String { "\(category) \(celsius)\(identified ? "" : " unidentified")" }
    }

    /// Contract 5.
    @Test(arguments: [
        Case(category: .cpu, celsius: 84, expected: 0),
        Case(category: .cpu, celsius: 90, expected: 0.5),
        Case(category: .cpu, celsius: 94, expected: 0.74),
        Case(category: .cpu, celsius: 95, expected: 0.8),
        Case(category: .cpu, celsius: 97, expected: 0.8),
        Case(category: .gpu, celsius: 84, expected: 0),
        Case(category: .gpu, celsius: 90, expected: 0.5),
        Case(category: .gpu, celsius: 94, expected: 0.74),
        Case(category: .gpu, celsius: 95, expected: 0.8),
        Case(category: .gpu, celsius: 97, expected: 0.8),
        Case(category: .cpuDie, celsius: 99, expected: 0),
        Case(category: .battery, celsius: 50, expected: 0),
        Case(category: .storage, celsius: 72, expected: 0),
        Case(category: .memory, celsius: 82, expected: 0),
        Case(category: .power, celsius: 120, expected: 0),
        Case(category: .enclosure, celsius: 90, expected: 0),
        Case(category: .cpu, celsius: 95, expected: 0, identified: false),
    ])
    func `floor of a reading by category`(row: Case) {
        let reading = Fixtures.reading(row.celsius, category: row.category, identified: row.identified)
        let floor = SafetyPolicy.minimumSpeed(readings: [reading], thermalState: .nominal)
        #expect(abs(floor - row.expected) < 1e-9)
    }

    /// Contract 5: the hottest cpu/gpu reading sets the floor; other categories add nothing.
    @Test func `the hottest floor reading wins`() {
        let readings = [Fixtures.reading(90, category: .cpu), Fixtures.reading(95, category: .gpu), Fixtures.reading(99, category: .cpuDie)]
        #expect(abs(SafetyPolicy.minimumSpeed(readings: readings, thermalState: .nominal) - 0.8) < 1e-9)
    }

    /// Contract 5: serious and critical pressure give at least 0.6 with cool readings; fair and nominal give 0.
    @Test(arguments: [
        (ProcessInfo.ThermalState.nominal, 0.0), (.fair, 0), (.serious, 0.6), (.critical, 0.6),
    ])
    func `pressure sets a minimum`(state: ProcessInfo.ThermalState, expected: Double) {
        let floor = SafetyPolicy.minimumSpeed(readings: [Fixtures.reading(50)], thermalState: state)
        #expect(abs(floor - expected) < 1e-9)
    }

    /// Contract 5: the floor is the larger of the reading and the pressure minimum.
    @Test func `a hot reading beats the pressure minimum`() {
        let floor = SafetyPolicy.minimumSpeed(readings: [Fixtures.reading(95)], thermalState: .serious)
        #expect(abs(floor - 0.8) < 1e-9)
    }
}

@Suite("Planner order and pressure latch")
struct PressureLatchTests {
    /// How a sample starts an emergency.
    enum Trigger: CaseIterable, Sendable { case temperature, pressure }

    func emergencySample(_ trigger: Trigger, at seconds: Double) -> HardwareSnapshot {
        switch trigger {
        case .temperature: Sample.at(seconds, cpu: 100)
        case .pressure: Sample.at(seconds, cpu: 60, .critical)
        }
    }

    /// Contract 1: the emergency is returned on the very sample that starts it, whatever the governor holds.
    /// Setup: floor 0.5 at +1, then the floor falls at +2 so the governor holds 0.5 inside its hold.
    @Test(arguments: [CoolingMode.fixed, .curve], Trigger.allCases)
    func `an emergency wins over a governor that is holding`(mode: CoolingMode, trigger: Trigger) {
        var planner = CoolingPlanner()
        let settings = Sample.settings(mode)
        _ = planner.decide(settings: settings, snapshot: Sample.at(0, cpu: 60))
        #expect(Sample.speed(planner.decide(settings: settings, snapshot: Sample.at(1, cpu: 90))) == 0.5)
        #expect(Sample.speed(planner.decide(settings: settings, snapshot: Sample.at(2, cpu: 70))) == 0.5, "held, so the governor is mid-hold")
        #expect(planner.decide(settings: settings, snapshot: emergencySample(trigger, at: 3)) == .system(.emergency))
    }

    /// Contract 1: Max keeps running at full speed, Automatic stays with the user.
    @Test(arguments: Trigger.allCases)
    func `max and automatic are not rescued`(trigger: Trigger) {
        var planner = CoolingPlanner()
        #expect(planner.decide(settings: Sample.settings(.max), snapshot: emergencySample(trigger, at: 0)) == .manual(speed: 1, temperature: nil))
        #expect(planner.decide(settings: Sample.settings(.automatic), snapshot: emergencySample(trigger, at: 1)) == .system(.userChoice))
    }

    /// Contract 2: the latch starts at critical, survives serious, and ends at fair or nominal.
    @Test(arguments: [CoolingMode.fixed, .curve], [ProcessInfo.ThermalState.fair, .nominal])
    func `pressure latch stays through serious and ends at fair or nominal`(mode: CoolingMode, recovered: ProcessInfo.ThermalState) {
        var planner = CoolingPlanner()
        let settings = Sample.settings(mode)
        #expect(planner.decide(settings: settings, snapshot: Sample.at(0, cpu: 60, .critical)) == .system(.emergency))
        #expect(planner.decide(settings: settings, snapshot: Sample.at(1, cpu: 60, .serious)) == .system(.emergency))
        #expect(planner.decide(settings: settings, snapshot: Sample.at(2, cpu: 60, recovered)) != .system(.emergency))
    }

    /// Contract 2: serious pressure alone does not start the emergency.
    @Test(arguments: [CoolingMode.fixed, .curve])
    func `serious pressure alone is not an emergency`(mode: CoolingMode) {
        var planner = CoolingPlanner()
        #expect(planner.decide(settings: Sample.settings(mode), snapshot: Sample.at(0, cpu: 60, .serious)) != .system(.emergency))
    }

    /// Contract 2: the latch updates with no readings. Critical with an empty snapshot is an emergency, not `noData`.
    @Test(arguments: [CoolingMode.fixed, .curve])
    func `critical pressure with no readings is an emergency`(mode: CoolingMode) {
        var planner = CoolingPlanner()
        let settings = Sample.settings(mode)
        #expect(planner.decide(settings: settings, snapshot: Sample.at(0, .critical)) == .system(.emergency))
        #expect(planner.decide(settings: settings, snapshot: Sample.at(1, .serious)) == .system(.emergency), "still latched with no readings")
        #expect(planner.decide(settings: settings, snapshot: Sample.at(2, .fair)) == .system(.noData), "cleared without readings, then missing data")
    }

    /// Contract 3: clearing pressure does not clear a temperature emergency that is still inside the margin (≥ 95).
    @Test(arguments: [CoolingMode.fixed, .curve])
    func `fair pressure does not end a hot emergency`(mode: CoolingMode) {
        var planner = CoolingPlanner()
        let settings = Sample.settings(mode)
        #expect(planner.decide(settings: settings, snapshot: Sample.at(0, cpu: 100, .critical)) == .system(.emergency))
        #expect(planner.decide(settings: settings, snapshot: Sample.at(1, cpu: 96, .fair)) == .system(.emergency))
        #expect(planner.decide(settings: settings, snapshot: Sample.at(2, cpu: 94, .fair)) != .system(.emergency))
    }

    /// Contract 3: a temperature recovery does not clear pressure that is still latched (serious after critical).
    @Test(arguments: [CoolingMode.fixed, .curve])
    func `a cool reading does not end a pressure emergency`(mode: CoolingMode) {
        var planner = CoolingPlanner()
        let settings = Sample.settings(mode)
        #expect(planner.decide(settings: settings, snapshot: Sample.at(0, cpu: 100, .critical)) == .system(.emergency))
        #expect(planner.decide(settings: settings, snapshot: Sample.at(1, cpu: 90, .serious)) == .system(.emergency))
        #expect(planner.decide(settings: settings, snapshot: Sample.at(2, cpu: 90, .nominal)) != .system(.emergency))
    }
}

@Suite("Floor invariant")
struct FloorInvariantTests {
    /// Contract 4: 0.49 then a floor of 0.50 gives at least 0.50. A rise check of `target > current + deadband`
    /// (which swallows the 0.01) fails here in both modes.
    @Test(arguments: [CoolingMode.fixed, .curve])
    func `a rise inside the deadband still reaches the floor`(mode: CoolingMode) {
        var planner = CoolingPlanner()
        // Curve mode: the curve itself gives 0.49, so only the floor can lift the target to 0.50.
        let settings = Sample.settings(mode, fixed: 0.2, curve: 0.49)
        let first = planner.decide(settings: settings, snapshot: Sample.at(0, cpu: 89.9))
        let second = planner.decide(settings: settings, snapshot: Sample.at(1, cpu: 90))
        #expect(Sample.speed(first).map { $0 >= 0.49 - 1e-9 } == true)
        #expect(Sample.speed(second).map { $0 >= 0.5 } == true)
    }

    /// Contract 4: serious pressure steps the floor from 0.59 to 0.60 (a cpu at 91.5 gives 0.59).
    @Test(arguments: [CoolingMode.fixed, .curve])
    func `serious pressure reaches 0_6 from 0_59`(mode: CoolingMode) {
        var planner = CoolingPlanner()
        let settings = Sample.settings(mode, fixed: 0.2, curve: 0.2)
        let first = planner.decide(settings: settings, snapshot: Sample.at(0, cpu: 91.5))
        #expect(abs((Sample.speed(first) ?? 0) - 0.59) < 1e-9)
        let second = planner.decide(settings: settings, snapshot: Sample.at(1, cpu: 91.5, .serious))
        #expect(Sample.speed(second).map { $0 >= 0.6 } == true)
    }

    /// Contract 4: on every sample of a fixed sequence, every `.manual` speed is at least the floor of that same snapshot.
    @Test(arguments: [CoolingMode.fixed, .curve])
    func `every manual speed is at least the floor on every sample`(mode: CoolingMode) {
        let steps: [(at: Double, cpu: Double, state: ProcessInfo.ThermalState)] = [
            (0, 60, .nominal), (1, 89.9, .nominal), (2, 90, .nominal), (2, 93, .nominal), (3, 60, .nominal),
            (4, 91.5, .nominal), (5, 91.5, .serious), (6, 70, .serious), (7, 70, .fair), (8, 96, .nominal),
            (9, 99.9, .nominal), (10, 70, .nominal), (11, 90, .nominal), (40, 60, .nominal), (41, 94, .fair),
        ]
        var planner = CoolingPlanner()
        let settings = Sample.settings(mode, fixed: 0.2, curve: 0.1)
        var manualSamples = 0
        for step in steps {
            let snapshot = Sample.at(step.at, cpu: step.cpu, step.state)
            let floor = SafetyPolicy.minimumSpeed(readings: snapshot.readings, thermalState: snapshot.thermalState)
            if let speed = Sample.speed(planner.decide(settings: settings, snapshot: snapshot)) {
                manualSamples += 1
                #expect(speed >= floor, "t=\(step.at) cpu=\(step.cpu) \(step.state): \(speed) < \(floor)")
            }
        }
        #expect(manualSamples == steps.count, "no sample should hand back to macOS")
    }
}

@Suite("Speed in each mode")
struct ModeSpeedTests {
    /// Contract 6: a change of the fixed slider applies at once, in both directions (no rise cap).
    @Test func `fixed speed changes apply immediately`() {
        var planner = CoolingPlanner()
        #expect(Sample.speed(planner.decide(settings: Sample.settings(.fixed, fixed: 0.3), snapshot: Sample.at(0, cpu: 60))) == 0.3)
        #expect(Sample.speed(planner.decide(settings: Sample.settings(.fixed, fixed: 0.7), snapshot: Sample.at(1, cpu: 60))) == 0.7)
        #expect(Sample.speed(planner.decide(settings: Sample.settings(.fixed, fixed: 0.3), snapshot: Sample.at(2, cpu: 60))) == 0.3)
    }

    /// Contract 6: fixed returns the larger of the slider and the governed floor.
    @Test(arguments: [(0.2, 0.5), (0.8, 0.8)])
    func `fixed is raised to the floor`(fixed: Double, expected: Double) {
        var planner = CoolingPlanner()
        let decision = planner.decide(settings: Sample.settings(.fixed, fixed: fixed), snapshot: Sample.at(0, cpu: 90))
        #expect(decision == .manual(speed: expected, temperature: nil))
    }

    /// Contract 6: once the floor has passed, fixed falls back to the slider only after the hold and gradually.
    @Test func `a falling floor comes down through the hold`() throws {
        var planner = CoolingPlanner()
        let settings = Sample.settings(.fixed, fixed: 0.2)
        _ = planner.decide(settings: settings, snapshot: Sample.at(0, cpu: 95))
        #expect(Sample.speed(planner.decide(settings: settings, snapshot: Sample.at(5, cpu: 60))) == 0.8, "inside the hold")
        let later = try #require(Sample.speed(planner.decide(settings: settings, snapshot: Sample.at(12, cpu: 60))))
        #expect(abs(later - 0.72) < 1e-9, "2 s past the hold at 0.04/s")
    }

    /// Contract 10: a change of mode resets pacing. Without the reset the governor would hold 0.8 for the fixed call.
    @Test func `curve at 0_8 then fixed 0_3 gives 0_3`() {
        var planner = CoolingPlanner()
        #expect(Sample.speed(planner.decide(settings: Sample.settings(.curve, curve: 0.8), snapshot: Sample.at(0, cpu: 60))) == 0.8)
        #expect(Sample.speed(planner.decide(settings: Sample.settings(.fixed, fixed: 0.3), snapshot: Sample.at(1, cpu: 60))) == 0.3)
    }

    /// Contract 10: the same reset in the other direction (fixed held a floor, curve wants less).
    @Test func `fixed with a floor then curve below it follows the curve`() {
        var planner = CoolingPlanner()
        #expect(Sample.speed(planner.decide(settings: Sample.settings(.fixed, fixed: 0.2), snapshot: Sample.at(0, cpu: 90))) == 0.5)
        // 90°C is the hottest cpu, so the floor still applies on the curve call: use cool readings.
        #expect(Sample.speed(planner.decide(settings: Sample.settings(.curve, curve: 0.1), snapshot: Sample.at(1, cpu: 60))) == 0.1)
    }

    /// Contract 12: a snapshot built without a thermal state is nominal.
    @Test func `a snapshot defaults to nominal pressure`() {
        let snapshot = HardwareSnapshot(date: Date(timeIntervalSince1970: 0), readings: [], fans: [], battery: nil)
        #expect(snapshot.thermalState == .nominal)
    }

    /// Contract 12: the curve reports the core temperature, and a hot die (92°C) does not raise the floor.
    @Test func `a hot die does not raise the curve or the floor`() throws {
        var planner = CoolingPlanner()
        var settings = CoolingSettings()
        settings.mode = .curve
        settings.preset = .balanced
        let snapshot = Fixtures.snapshot([Fixtures.reading(60, id: "core"), Fixtures.reading(92, category: .cpuDie, id: "die")])
        let expected = try #require(CurvePreset.balanced.curve).speed(at: 60)
        #expect(planner.decide(settings: settings, snapshot: snapshot) == .manual(speed: expected, temperature: 60))
    }

    /// Contract 12 in Fixed: a hot die adds no floor.
    @Test func `a hot die does not raise fixed speed`() {
        var planner = CoolingPlanner()
        let snapshot = Fixtures.snapshot([Fixtures.reading(60, id: "core"), Fixtures.reading(92, category: .cpuDie, id: "die")])
        #expect(planner.decide(settings: Sample.settings(.fixed, fixed: 0.2), snapshot: snapshot) == .manual(speed: 0.2, temperature: nil))
    }
}

@Suite("Curve below the safety minimum")
struct BelowMinimumTests {
    /// Contract 11: no preset is below the floor.
    @Test(arguments: CurvePreset.allCases.filter { $0 != .custom })
    func `presets are not below the minimum`(preset: CurvePreset) throws {
        #expect(try !SafetyPolicy.isBelowMinimum(#require(preset.curve)))
    }

    /// Contract 11: a custom curve is below the floor when any point of either curve is under it,
    /// including a floor point (90, 0.5) that the curve passes between its own points.
    @Test(arguments: [
        [(40.0, 0.0), (90.0, 0.4), (100.0, 1.0)],
        [(84.0, 0.0), (100.0, 0.8)],  // both points are on the floor, but the chord dips below it at 90 and 95
    ])
    func `a curve under the floor is flagged`(points: [(Double, Double)]) {
        #expect(SafetyPolicy.isBelowMinimum(FanCurve(points)))
    }

    /// Contract 11: a curve that touches the floor exactly is not below it.
    @Test func `a curve on the floor is not flagged`() {
        #expect(!SafetyPolicy.isBelowMinimum(FanCurve([(85, 0), (90, 0.5), (95, 0.8)])))
    }
}
