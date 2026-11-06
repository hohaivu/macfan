import Foundation
import Testing
@testable import MacFanCore

/// A helper stand-in that records commands and can fail or pause on demand.
@MainActor
final class FakeCommander: FanCommanding {
    enum Failure: Error { case write, restore }

    var isReady = true
    private(set) var log: [String] = []
    /// The rpm of every target, in order.
    private(set) var rpms: [Double] = []
    var failingFans: Set<Int> = []
    var failRestore = false
    /// Pauses `setTarget` for this fan until `releasePausedTarget()`.
    var pauseFan: Int?
    private var paused: CheckedContinuation<Void, Never>?

    var isPaused: Bool { paused != nil }

    func setTarget(rpm: Double, fanIndex: Int) async throws {
        log.append("target \(fanIndex)")
        rpms.append(rpm)
        if pauseFan == fanIndex {
            pauseFan = nil
            await withCheckedContinuation { paused = $0 }
        }
        if failingFans.contains(fanIndex) { throw Failure.write }
    }

    func restoreSystemControl() async throws {
        log.append("restore")
        if failRestore { throw Failure.restore }
    }

    func restoreSystemControlBlocking() {
        log.append("restore (blocking)")
    }

    func releasePausedTarget() {
        paused?.resume()
        paused = nil
    }
}

/// A user setting at which the engine drives the fans: Max, or a Fixed / Curve setting held in an emergency.
enum Drive: CaseIterable, Sendable, CustomTestStringConvertible {
    case max, fixedEmergency, curveEmergency

    var testDescription: String {
        switch self {
        case .max: "max"
        case .fixedEmergency: "fixed in an emergency"
        case .curveEmergency: "curve in an emergency"
        }
    }

    var settings: CoolingSettings {
        switch self {
        case .max: userSettings(.max)
        case .fixedEmergency: userSettings(.fixed)
        case .curveEmergency: userSettings(.curve)
        }
    }

    /// Max needs no emergency; the others read cpu 100, the critical temperature.
    func snapshot(fans: [FanStatus]) -> HardwareSnapshot {
        Fixtures.snapshot([Fixtures.reading(self == .max ? 60 : 100)], fans: fans)
    }

    var state: FanControlEngine.State {
        self == .max ? .controlling(speed: 1) : .emergency
    }
}

/// Fixed 0.2, or Curve on a flat custom curve at 0.3. `keeps` is `keepsSettingInEmergency`.
func userSettings(_ mode: CoolingMode, keeps: Bool = false) -> CoolingSettings {
    var settings = CoolingSettings()
    settings.mode = mode
    settings.fixedSpeed = 0.2
    settings.preset = .custom
    settings.customCurve = FanCurve([(40, 0.3), (80, 0.3)])
    settings.keepsSettingInEmergency = keeps
    return settings
}

@MainActor
@Suite("FanControlEngine")
struct FanControlEngineTests {
    let twoFans = [Fixtures.fan(index: 0), Fixtures.fan(index: 1)]

    func snapshot() -> HardwareSnapshot {
        Fixtures.snapshot([Fixtures.reading(60)], fans: twoFans)
    }

    func settings(_ mode: CoolingMode) -> CoolingSettings {
        var settings = CoolingSettings()
        settings.mode = mode
        return settings
    }

    /// Two fans at the given cpu temperature and thermal state, one second apart per `seconds`.
    func sample(cpu: Double, _ state: ProcessInfo.ThermalState = .nominal, at seconds: Double) -> HardwareSnapshot {
        Fixtures.snapshot([Fixtures.reading(cpu)], at: Date(timeIntervalSince1970: seconds), fans: twoFans, thermalState: state)
    }

    /// R1: a failed hand-back must stay visible and be retried.
    @Test(arguments: Drive.allCases)
    func `a failed restore is reported and retried`(drive: Drive) async {
        let commander = FakeCommander()
        let engine = FanControlEngine(commander: commander)
        await engine.update(settings: drive.settings, snapshot: drive.snapshot(fans: twoFans))
        #expect(engine.state == drive.state)

        commander.failRestore = true
        await engine.update(settings: settings(.automatic), snapshot: snapshot())
        #expect(engine.state == .failed("Couldn't give the fans back to macOS"))

        commander.failRestore = false
        await engine.update(settings: settings(.automatic), snapshot: snapshot())
        #expect(engine.state == .system)
        #expect(commander.log.filter { $0 == "restore" }.count == 2)
    }

    /// R2: a write that fails halfway must still be undone.
    @Test(arguments: Drive.allCases)
    func `a partial target failure is handed back`(drive: Drive) async {
        let commander = FakeCommander()
        let engine = FanControlEngine(commander: commander)
        await engine.update(settings: settings(.automatic), snapshot: snapshot())

        commander.failingFans = [1]
        await engine.update(settings: drive.settings, snapshot: drive.snapshot(fans: twoFans))
        #expect(commander.log.suffix(3) == ["target 0", "target 1", "restore"])
        if case .failed = engine.state {} else { Issue.record("Expected .failed, got \(engine.state)") }
    }

    /// R2: if even that hand-back fails, the next Automatic tick and shutdown still try.
    @Test(arguments: Drive.allCases)
    func `a partial failure keeps the restore obligation`(drive: Drive) async {
        let commander = FakeCommander()
        let engine = FanControlEngine(commander: commander)
        await engine.update(settings: settings(.automatic), snapshot: snapshot())

        commander.failingFans = [1]
        commander.failRestore = true
        await engine.update(settings: drive.settings, snapshot: drive.snapshot(fans: twoFans))

        commander.failRestore = false
        await engine.update(settings: settings(.automatic), snapshot: snapshot())
        #expect(commander.log.last == "restore")
        #expect(engine.state == .system)
    }

    @Test(arguments: Drive.allCases)
    func `shutdown hands back after a partial failure`(drive: Drive) async {
        let commander = FakeCommander()
        let engine = FanControlEngine(commander: commander)
        await engine.update(settings: settings(.automatic), snapshot: snapshot())

        commander.failingFans = [1]
        commander.failRestore = true
        await engine.update(settings: drive.settings, snapshot: drive.snapshot(fans: twoFans))
        engine.shutdown()
        #expect(commander.log.last == "restore (blocking)")
    }

    /// R3: sleep arriving mid-update must win; no target may follow the hand-back.
    @Test(arguments: Drive.allCases)
    func `suspend during an update ends with a hand-back`(drive: Drive) async {
        let commander = FakeCommander()
        let engine = FanControlEngine(commander: commander)
        await engine.update(settings: settings(.automatic), snapshot: snapshot())

        commander.pauseFan = 0
        let update = Task { await engine.update(settings: drive.settings, snapshot: drive.snapshot(fans: twoFans)) }
        while !commander.isPaused { await Task.yield() }

        await engine.suspend()
        commander.releasePausedTarget()
        await update.value

        #expect(commander.log.suffix(2) == ["target 0", "restore"])
        #expect(engine.state == .system)
    }

    @Test(arguments: Drive.allCases)
    func `updates are ignored while suspended`(drive: Drive) async {
        let commander = FakeCommander()
        let engine = FanControlEngine(commander: commander)
        await engine.suspend()
        let before = commander.log
        await engine.update(settings: drive.settings, snapshot: drive.snapshot(fans: twoFans))
        #expect(commander.log == before)

        engine.resume()
        await engine.update(settings: drive.settings, snapshot: drive.snapshot(fans: twoFans))
        #expect(commander.log.suffix(2) == ["target 0", "target 1"])
    }

    @Test(arguments: Drive.allCases)
    func `fans with unknown limits are never driven`(drive: Drive) async {
        let commander = FakeCommander()
        let engine = FanControlEngine(commander: commander)
        let unknown = FanStatus(index: 0, name: "Fan", currentRPM: 2000, minimumRPM: 0, maximumRPM: 2000,
                                targetRPM: nil, isManual: false, hasKnownLimits: false)
        await engine.update(settings: drive.settings, snapshot: drive.snapshot(fans: [unknown]))
        #expect(!commander.log.contains { $0.hasPrefix("target") })
        #expect(commander.log.contains("restore"), "the first tick still owes macOS the fans")
        if case .failed = engine.state {} else { Issue.record("Expected .failed, got \(engine.state)") }
    }

    @Test(arguments: Drive.allCases)
    func `without the helper nothing is sent`(drive: Drive) async {
        let commander = FakeCommander()
        commander.isReady = false
        let engine = FanControlEngine(commander: commander)
        await engine.update(settings: drive.settings, snapshot: drive.snapshot(fans: twoFans))
        #expect(engine.state == .needsHelper)
        #expect(commander.log.isEmpty)
    }

    @Test(arguments: Drive.allCases)
    func `shutdown after successful drive control restores`(drive: Drive) async {
        let commander = FakeCommander()
        let engine = FanControlEngine(commander: commander)
        await engine.update(settings: drive.settings, snapshot: drive.snapshot(fans: twoFans))
        #expect(engine.state == drive.state)
        engine.shutdown()
        #expect(commander.log.last == "restore (blocking)")
    }

    /// Enter, hold and leave an emergency. Every tick writes every fan, full speed while the latch holds, and the
    /// fans never go back to macOS: not on entry, not during the emergency, not on recovery.
    @Test(arguments: [CoolingMode.fixed, .curve], PressureLatchTests.Trigger.allCases)
    func `an emergency runs every fan at full speed and recovers to the setting`(mode: CoolingMode, trigger: PressureLatchTests.Trigger) async throws {
        let commander = FakeCommander()
        let engine = FanControlEngine(commander: commander)
        let settings = userSettings(mode)
        let maximum = try #require(twoFans.first).maximumRPM

        await engine.update(settings: settings, snapshot: sample(cpu: 60, at: 0))
        guard case .controlling = engine.state else { Issue.record("expected .controlling, got \(engine.state)"); return }
        #expect(!engine.isCriticallyHot)
        #expect(commander.rpms.count == 2)
        #expect(commander.rpms.allSatisfy { $0 < maximum })

        switch trigger {
        case .temperature: await engine.update(settings: settings, snapshot: sample(cpu: 100, at: 1))
        case .pressure: await engine.update(settings: settings, snapshot: sample(cpu: 60, .critical, at: 1))
        }
        #expect(engine.state == .emergency)
        #expect(engine.isCriticallyHot)
        #expect(commander.rpms.count == 4)
        #expect(commander.rpms.suffix(2) == [maximum, maximum])

        switch trigger {
        case .temperature: await engine.update(settings: settings, snapshot: sample(cpu: 96, at: 2))
        case .pressure: await engine.update(settings: settings, snapshot: sample(cpu: 60, .serious, at: 2))
        }
        #expect(engine.state == .emergency, "still latched")
        #expect(engine.isCriticallyHot)
        #expect(commander.rpms.count == 6, "the heartbeat writes again")
        #expect(commander.rpms.suffix(2) == [maximum, maximum])

        let expected: Double
        switch trigger {
        case .temperature:
            await engine.update(settings: settings, snapshot: sample(cpu: 94, at: 3))
            expected = 0.74
        case .pressure:
            await engine.update(settings: settings, snapshot: sample(cpu: 60, .fair, at: 3))
            expected = mode == .fixed ? 0.2 : 0.3
        }
        guard case let .controlling(speed) = engine.state else { Issue.record("expected .controlling, got \(engine.state)"); return }
        #expect(abs(speed - expected) < 1e-9)
        #expect(!engine.isCriticallyHot)
        #expect(commander.rpms.count == 8)
        #expect(commander.rpms.suffix(2).allSatisfy { $0 < maximum })

        #expect(!commander.log.contains("restore"), "never handed to macOS on the way in, during or on the way out")
    }

    /// Switching to Automatic mid-emergency does hand the fans back.
    @Test(arguments: [CoolingMode.fixed, .curve])
    func `an emergency hands back when the user picks automatic`(mode: CoolingMode) async {
        let commander = FakeCommander()
        let engine = FanControlEngine(commander: commander)
        await engine.update(settings: userSettings(mode), snapshot: sample(cpu: 100, at: 0))
        #expect(engine.state == .emergency)
        #expect(!commander.log.contains("restore"))

        await engine.update(settings: settings(.automatic), snapshot: sample(cpu: 100, at: 1))
        #expect(commander.log.last == "restore")
        #expect(engine.state == .system)
    }

    /// A pressure emergency that clears while no readings arrive means missing data: the fans go back to macOS.
    @Test(arguments: [CoolingMode.fixed, .curve])
    func `cleared pressure with no readings hands back as no data`(mode: CoolingMode) async {
        let commander = FakeCommander()
        let engine = FanControlEngine(commander: commander)
        let settings = userSettings(mode)
        let maximum = twoFans[0].maximumRPM

        await engine.update(settings: settings, snapshot: Fixtures.snapshot([], fans: twoFans, thermalState: .critical))
        #expect(engine.state == .emergency, "critical pressure alone, with no readings")
        #expect(commander.rpms == [maximum, maximum])
        #expect(!commander.log.contains("restore"))

        await engine.update(settings: settings, snapshot: Fixtures.snapshot([], fans: twoFans, thermalState: .fair))
        #expect(commander.log.last == "restore")
        #expect(engine.state == .noData)
        #expect(!engine.isCriticallyHot)
    }

    /// Opt-in: with the flag on a latch drives the user's setting (raised to the floor), not full speed, and still never restores.
    /// Turning the flag off on the next tick gives full speed.
    @Test(arguments: [CoolingMode.fixed, .curve], PressureLatchTests.Trigger.allCases)
    func `keeping the setting drives below full speed until the flag is turned off`(mode: CoolingMode, trigger: PressureLatchTests.Trigger) async {
        let commander = FakeCommander()
        let engine = FanControlEngine(commander: commander)
        let maximum = twoFans[0].maximumRPM

        switch trigger {
        case .temperature: await engine.update(settings: userSettings(mode, keeps: true), snapshot: sample(cpu: 100, at: 0))
        case .pressure: await engine.update(settings: userSettings(mode, keeps: true), snapshot: sample(cpu: 60, .critical, at: 0))
        }
        guard case .controlling = engine.state else { Issue.record("expected .controlling, got \(engine.state)"); return }
        #expect(engine.isCriticallyHot)
        #expect(commander.rpms.count == 2)
        #expect(commander.rpms.allSatisfy { $0 < maximum })

        switch trigger {
        case .temperature: await engine.update(settings: userSettings(mode), snapshot: sample(cpu: 96, at: 1))
        case .pressure: await engine.update(settings: userSettings(mode), snapshot: sample(cpu: 60, .serious, at: 1))
        }
        #expect(engine.state == .emergency)
        #expect(commander.rpms.suffix(2) == [maximum, maximum])
        #expect(!commander.log.contains("restore"))
    }

    /// `isCriticallyHot` is exactly "a latch is set" after every update, in every mode, whatever the flag.
    @Test(arguments: CoolingMode.allCases.flatMap { mode in [false, true].map { (mode, $0) } }, PressureLatchTests.Trigger.allCases)
    func `isCriticallyHot follows the latches`(config: (mode: CoolingMode, keeps: Bool), trigger: PressureLatchTests.Trigger) async {
        let commander = FakeCommander()
        let engine = FanControlEngine(commander: commander)
        let settings = userSettings(config.mode, keeps: config.keeps)

        await engine.update(settings: settings, snapshot: sample(cpu: 60, at: 0))
        #expect(!engine.isCriticallyHot)

        switch trigger {
        case .temperature: await engine.update(settings: settings, snapshot: sample(cpu: 100, at: 1))
        case .pressure: await engine.update(settings: settings, snapshot: sample(cpu: 60, .critical, at: 1))
        }
        #expect(engine.isCriticallyHot)

        switch trigger {
        case .temperature: await engine.update(settings: settings, snapshot: sample(cpu: 96, at: 2))
        case .pressure: await engine.update(settings: settings, snapshot: sample(cpu: 60, .serious, at: 2))
        }
        #expect(engine.isCriticallyHot, "still latched")

        switch trigger {
        case .temperature: await engine.update(settings: settings, snapshot: sample(cpu: 94, at: 3))
        case .pressure: await engine.update(settings: settings, snapshot: sample(cpu: 60, .fair, at: 3))
        }
        #expect(!engine.isCriticallyHot)
    }
}
