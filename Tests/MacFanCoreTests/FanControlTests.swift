import Foundation
import Testing
@testable import MacFanCore

@Suite("FanCurve")
struct FanCurveTests {
    let curve = FanCurve([(40, 0), (60, 0.5), (80, 1)])

    @Test func `interpolates between points`() {
        #expect(curve.speed(at: 50) == 0.25)
        #expect(curve.speed(at: 70) == 0.75)
    }

    @Test func `holds flat outside the curve`() {
        #expect(curve.speed(at: 20) == 0)
        #expect(curve.speed(at: 100) == 1)
    }

    @Test func `normalization sorts and forbids hotter being slower`() {
        let messy = FanCurve([(80, 0.2), (40, 0.6), (60, 0.1)])
        #expect(messy.points.map(\.temperature) == [40, 60, 80])
        #expect(messy.points.map(\.speed) == [0.6, 0.6, 0.6])
    }

    @Test func `normalization separates duplicate temperatures`() {
        let duplicates = FanCurve([(50, 0), (50, 1)])
        #expect(duplicates.points[1].temperature == 50 + FanCurve.minimumGap)
    }

    @Test func `moving up lifts later points`() {
        var edited = curve
        edited.move(pointAt: 0, to: CurvePoint(temperature: 40, speed: 0.8))
        #expect(edited.points.map(\.speed) == [0.8, 0.8, 1])
    }

    @Test func `moving down lowers earlier points`() {
        var edited = curve
        edited.move(pointAt: 2, to: CurvePoint(temperature: 80, speed: 0.2))
        #expect(edited.points.map(\.speed) == [0, 0.2, 0.2])
    }

    @Test func `points cannot pass their neighbours`() {
        var edited = curve
        edited.move(pointAt: 1, to: CurvePoint(temperature: 95, speed: 0.5))
        #expect(edited.points[1].temperature == 80 - FanCurve.minimumGap)
    }

    @Test func `presets are valid`() throws {
        for preset in CurvePreset.allCases where preset != .custom {
            let curve = try #require(preset.curve)
            #expect(curve.points.first?.speed ?? 1 <= curve.points.last?.speed ?? 0)
        }
    }
}

@Suite("SpeedGovernor")
struct SpeedGovernorTests {
    let start = Date(timeIntervalSince1970: 0)

    /// Contract 7: a non-urgent rise is capped at 0.15/s.
    @Test func `a non-urgent rise is capped per second`() {
        var governor = SpeedGovernor()
        _ = governor.next(target: 0.2, at: start)
        #expect(abs(governor.next(target: 0.9, at: start + 1) - 0.35) < 1e-9)
    }

    /// Contract 7: an urgent rise is met at once.
    @Test func `an urgent rise is immediate`() {
        var governor = SpeedGovernor()
        _ = governor.next(target: 0.2, at: start)
        #expect(governor.next(target: 0.9, at: start + 1, urgent: true) == 0.9)
    }

    /// Contract 7: a rise has no deadband, urgent or not. A rise check of `target > current + deadband` fails both.
    @Test(arguments: [false, true])
    func `a tiny rise is not swallowed by the deadband`(urgent: Bool) {
        var governor = SpeedGovernor()
        _ = governor.next(target: 0.50, at: start)
        #expect(abs(governor.next(target: 0.51, at: start + 1, urgent: urgent) - 0.51) < 1e-9)
    }

    /// Contract 8 (after the hold): falls at 0.04/s. The hold is switched off here to isolate the rate.
    @Test func `slows down gradually`() {
        var governor = SpeedGovernor()
        governor.holdTime = 0
        _ = governor.next(target: 1, at: start)
        let next = governor.next(target: 0, at: start + 2)
        #expect(abs(next - (1 - 2 * governor.maximumDecreasePerSecond)) < 0.0001)
    }

    /// Contract 8: the speed is held until the hold expires, which is 10 s after the last demand.
    /// A sample at +12 counts only the 2 s after expiry (0.92), whether or not +10 was sampled.
    /// A budget of `now - lastUpdate` gives 0.72 when +10 is skipped.
    @Test(arguments: [[5.0, 10, 12], [5.0, 12]])
    func `a fall waits for the hold and counts only time after it`(dates: [Double]) {
        var governor = SpeedGovernor()
        _ = governor.next(target: 1, at: start)
        var speeds: [Double] = []
        for offset in dates {
            speeds.append(governor.next(target: 0, at: start + offset))
        }
        #expect(speeds.dropLast().allSatisfy { $0 == 1 }, "held through +5 and the exact expiry at +10")
        #expect(abs(speeds.last! - 0.92) < 1e-9)
    }

    /// Contract 8: one sample long after the demand counts 20 s of fall time (30 s minus the 10 s hold).
    /// A budget of `now - lastUpdate` would give 0.
    @Test func `a single late sample falls for the time after the hold only`() {
        var governor = SpeedGovernor()
        _ = governor.next(target: 1, at: start)
        #expect(abs(governor.next(target: 0, at: start + 30) - 0.2) < 1e-9)
    }

    /// Contract 8: a fall never goes below the target.
    @Test func `a fall stops at the target`() {
        var governor = SpeedGovernor()
        _ = governor.next(target: 1, at: start)
        #expect(abs(governor.next(target: 0.9, at: start + 30) - 0.9) < 1e-9)
    }

    /// Contract 8: a target inside the deadband counts as demand and restarts the hold.
    @Test func `a target within the deadband restarts the hold`() {
        var governor = SpeedGovernor()
        _ = governor.next(target: 1, at: start)
        #expect(governor.next(target: 0.99, at: start + 8) == 1)
        // 4 s after the restart, not 12 s after the first demand.
        #expect(governor.next(target: 0, at: start + 12) == 1)
    }

    /// Contract 9: with `urgent` and no hold, the governor is the old one (instant rise, 0.02 deadband, 0.04/s fall).
    /// Expected values are worked out by hand from those rules.
    @Test func `matches the earlier governor when urgent without a hold`() {
        var governor = SpeedGovernor()
        governor.holdTime = 0
        let steps: [(at: Double, target: Double, expected: Double)] = [
            (0, 0.50, 0.50),    // first sample
            (1, 0.51, 0.51),    // tiny rise is instant
            (1, 0.30, 0.51),    // repeated date: no time to fall
            (2, 0.50, 0.51),    // fall of 0.01 is inside the deadband
            (3, 0.20, 0.47),    // 1 s at 0.04/s
            (8, 0.00, 0.27),    // 5 s at 0.04/s
            (100, 0.00, 0.00),  // long fall stops at the target
            (101, 0.90, 0.90),  // instant rise
        ]
        for step in steps {
            let speed = governor.next(target: step.target, at: start + step.at, urgent: true)
            #expect(abs(speed - step.expected) < 1e-9, "t=\(step.at) target=\(step.target)")
        }
        // Contract 9: a date earlier than the previous sample never lowers the speed.
        #expect(governor.next(target: 0, at: start + 50, urgent: true) >= 0.90 - 1e-9)
    }

    @Test func `ignores tiny decreases`() {
        var governor = SpeedGovernor()
        _ = governor.next(target: 0.5, at: start)
        #expect(governor.next(target: 0.49, at: start + 10) == 0.5)
    }
}

@Suite("CoolingPlanner")
struct CoolingPlannerTests {
    func settings(_ mode: CoolingMode) -> CoolingSettings {
        var settings = CoolingSettings()
        settings.mode = mode
        return settings
    }

    @Test func `automatic leaves fans to macOS`() {
        var planner = CoolingPlanner()
        let decision = planner.decide(settings: settings(.automatic), snapshot: Fixtures.snapshot([Fixtures.reading(60)]))
        #expect(decision == .system(.userChoice))
    }

    @Test func `fixed uses the chosen speed`() {
        var planner = CoolingPlanner()
        var fixed = settings(.fixed)
        fixed.fixedSpeed = 0.3
        #expect(planner.decide(settings: fixed, snapshot: Fixtures.snapshot([Fixtures.reading(60)])) == .manual(speed: 0.3, temperature: nil))
    }

    @Test func `curve follows its source`() {
        var planner = CoolingPlanner()
        var curve = settings(.curve)
        curve.preset = .custom
        curve.customCurve = FanCurve([(40, 0), (80, 1)])
        let snapshot = Fixtures.snapshot([Fixtures.reading(60), Fixtures.reading(30, category: .storage)])
        #expect(planner.decide(settings: curve, snapshot: snapshot) == .manual(speed: 0.5, temperature: 60))
    }

    @Test func `curve without data hands back to macOS`() {
        var planner = CoolingPlanner()
        var curve = settings(.curve)
        curve.source = .sensor(id: "missing")
        #expect(planner.decide(settings: curve, snapshot: Fixtures.snapshot([Fixtures.reading(60)])) == .system(.noData))
    }

    @Test func `critical temperature hands back to macOS`() {
        var planner = CoolingPlanner()
        let hot = Fixtures.snapshot([Fixtures.reading(SensorCategory.cpu.thresholds.critical + 1)])
        #expect(planner.decide(settings: settings(.fixed), snapshot: hot) == .system(.emergency))
        #expect(planner.decide(settings: settings(.curve), snapshot: hot) == .system(.emergency))
    }

    @Test func `max mode is never overridden`() {
        var planner = CoolingPlanner()
        let hot = Fixtures.snapshot([Fixtures.reading(SensorCategory.cpu.thresholds.critical + 1)])
        #expect(planner.decide(settings: settings(.max), snapshot: hot) == .manual(speed: 1, temperature: nil))
    }

    @Test func `emergency ends only after cooling down`() {
        var planner = CoolingPlanner()
        let critical = SensorCategory.cpu.thresholds.critical
        _ = planner.decide(settings: settings(.fixed), snapshot: Fixtures.snapshot([Fixtures.reading(critical)]))

        let slightlyCooler = Fixtures.snapshot([Fixtures.reading(critical - 1)])
        #expect(planner.decide(settings: settings(.fixed), snapshot: slightlyCooler) == .system(.emergency))

        let cool = Fixtures.snapshot([Fixtures.reading(critical - SafetyPolicy.recoveryMargin - 1)])
        #expect(planner.decide(settings: settings(.fixed), snapshot: cool) != .system(.emergency))
    }

    @Test func `unidentified or irrelevant sensors never trigger an emergency`() {
        let readings = [
            Fixtures.reading(120, category: .other, identified: false),
            Fixtures.reading(120, category: .enclosure),
        ]
        #expect(!SafetyPolicy.isEmergency(readings, wasInEmergency: false))
    }
}

@Suite("Fans")
struct FanTests {
    @Test func `speed maps onto the supported range`() {
        let fan = Fixtures.fan(minimum: 1000, maximum: 5000)
        #expect(fan.rpm(forSpeed: 0) == 1000)
        #expect(fan.rpm(forSpeed: 0.5) == 3000)
        #expect(fan.rpm(forSpeed: 2) == 5000)
    }

    @Test func `names`() {
        #expect(FanStatus.name(forIndex: 0, count: 1) == "Fan")
        #expect(FanStatus.name(forIndex: 1, count: 2) == "Fan 2")
    }
}

/// Die sensors run hotter than the cores. They must still hand back to macOS when truly hot,
/// but must not drive the default CPU number or the curve.
@Suite("CPU die sensors")
struct CPUDieTests {
    let critical = SensorCategory.cpu.thresholds.critical

    func settings(_ mode: CoolingMode) -> CoolingSettings {
        var settings = CoolingSettings()
        settings.mode = mode
        return settings
    }

    @Test func `category raw value, order and limits`() {
        #expect(SensorCategory.cpuDie.rawValue == "cpuDie")
        #expect(SensorCategory.cpuDie > .cpu && SensorCategory.cpuDie < .gpu)
        #expect(SensorCategory.cpuDie.thresholds == SensorCategory.cpu.thresholds)
        #expect(SensorCategory.cpuDie.thresholds.critical == 100)
        #expect(!SensorCategory.cpuDie.isSafetyRelevant)
    }

    @Test func `which categories trigger an emergency`() {
        let triggering: [SensorCategory] = [.cpu, .gpu, .memory, .storage, .battery, .cpuDie]
        for category in SensorCategory.allCases {
            #expect(category.triggersEmergency == triggering.contains(category), "\(category)")
        }
    }

    @Test(arguments: [CoolingMode.curve, .fixed])
    func `a hot die hands back to macOS while cores are cool`(mode: CoolingMode) {
        var planner = CoolingPlanner()
        let snapshot = Fixtures.snapshot([Fixtures.reading(60, id: "core"), Fixtures.reading(critical, category: .cpuDie, id: "die")])
        #expect(planner.decide(settings: settings(mode), snapshot: snapshot) == .system(.emergency))
    }

    @Test func `a hot die doesn't override max`() {
        var planner = CoolingPlanner()
        let snapshot = Fixtures.snapshot([Fixtures.reading(60, id: "core"), Fixtures.reading(critical + 5, category: .cpuDie, id: "die")])
        #expect(planner.decide(settings: settings(.max), snapshot: snapshot) == .manual(speed: 1, temperature: nil))
    }

    @Test func `a die just below the limit is not an emergency`() {
        var planner = CoolingPlanner()
        let snapshot = Fixtures.snapshot([Fixtures.reading(60, id: "core"), Fixtures.reading(critical - 0.1, category: .cpuDie, id: "die")])
        #expect(planner.decide(settings: settings(.fixed), snapshot: snapshot) != .system(.emergency))
    }

    @Test func `a die emergency recovers with the same margin as a core`() {
        var planner = CoolingPlanner()
        func die(_ celsius: Double) -> HardwareSnapshot {
            Fixtures.snapshot([Fixtures.reading(60, id: "core"), Fixtures.reading(celsius, category: .cpuDie, id: "die")])
        }
        _ = planner.decide(settings: settings(.fixed), snapshot: die(critical))
        #expect(planner.decide(settings: settings(.fixed), snapshot: die(critical - SafetyPolicy.recoveryMargin + 1)) == .system(.emergency))
        #expect(planner.decide(settings: settings(.fixed), snapshot: die(critical - SafetyPolicy.recoveryMargin - 0.1)) != .system(.emergency))
    }

    @Test func `a die reading gives the same emergency verdict as a core reading`() {
        for celsius in [60.0, 94.9, 95, 99.9, 100, 120] {
            for wasInEmergency in [false, true] {
                #expect(SafetyPolicy.isEmergency([Fixtures.reading(celsius, category: .cpuDie)], wasInEmergency: wasInEmergency)
                        == SafetyPolicy.isEmergency([Fixtures.reading(celsius, category: .cpu)], wasInEmergency: wasInEmergency),
                        "\(celsius) \(wasInEmergency)")
            }
        }
    }

    @Test func `the curve follows cores, not die readings`() throws {
        var planner = CoolingPlanner()
        var curve = settings(.curve)
        curve.preset = .balanced
        curve.source = .hottestCPU
        let snapshot = Fixtures.snapshot([Fixtures.reading(62, id: "core"), Fixtures.reading(83, category: .cpuDie, id: "die")])
        let expected = try #require(CurvePreset.balanced.curve).speed(at: 62)
        #expect(planner.decide(settings: curve, snapshot: snapshot) == .manual(speed: expected, temperature: 62))
    }

    @Test func `a curve won't follow die readings once the cores go quiet`() {
        var planner = CoolingPlanner()
        var curve = settings(.curve)
        curve.source = .hottestCPU
        _ = planner.decide(settings: curve, snapshot: Fixtures.snapshot([Fixtures.reading(62, id: "core"), Fixtures.reading(83, category: .cpuDie, id: "die")]))

        let dieOnly = Fixtures.snapshot([Fixtures.reading(83, category: .cpuDie, id: "die")])
        #expect(planner.decide(settings: curve, snapshot: dieOnly) == .system(.noData))
    }

    @Test func `die readings stay out of the default summaries and status`() {
        let snapshot = Fixtures.snapshot([Fixtures.reading(62, id: "core"), Fixtures.reading(95, category: .cpuDie, id: "die")])
        #expect(snapshot.worstLevel == .cool)
        #expect(snapshot.hottest(in: [.cpu])?.celsius == 62)
        #expect(!snapshot.summaries().filter(\.category.isSafetyRelevant).contains { $0.category == .cpuDie })
        #expect(snapshot.summaries().first { $0.category == .cpuDie }?.hottest.celsius == 95, "still listed for the Sensors view")
        #expect(snapshot.hottest()?.celsius == 95, "hottest overall still includes die readings")
    }
}
