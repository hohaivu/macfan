import Foundation
import Testing
@testable import SMCKit

/// R5: missing or nonsensical limits must stop manual control, never be invented.
@Suite("SMCFanControl limits")
struct SMCFanControlLimitTests {
    @Test func `reads valid limits`() throws {
        let fans = SMCFanControl(smc: FakeSMC.appleSilicon(), modeSwitchAttempts: 2, modeSwitchInterval: 0)
        let reading = try #require(fans.reading(fan: 0))
        #expect(reading.validLimits == 1200...6000)
    }

    @Test(arguments: ["F0Mn", "F0Mx"] as [SMCKey])
    func `a missing limit refuses to write a target`(missing: SMCKey) throws {
        let smc = FakeSMC.appleSilicon()
        smc.values[missing] = nil
        let fans = SMCFanControl(smc: smc, modeSwitchAttempts: 2, modeSwitchInterval: 0)

        #expect(try #require(fans.reading(fan: 0)).validLimits == nil)
        #expect(throws: SMCError.self) { try fans.setTarget(rpm: 0, fan: 0) }
        #expect(!smc.wrote("F0Tg"))
        #expect(!smc.wrote("F0Md"))
    }

    @Test(arguments: [
        (Double.nan, 6000.0),
        (1200, .infinity),
        (-100, 6000),
        (6000, 1200),
        (3000, 3000),
    ])
    func `nonsensical limits refuse to write a target`(minimum: Double, maximum: Double) {
        let smc = FakeSMC.appleSilicon()
        smc.values["F0Mn"] = minimum
        smc.values["F0Mx"] = maximum
        #expect(throws: SMCError.self) { try SMCFanControl(smc: smc, modeSwitchAttempts: 2, modeSwitchInterval: 0).setTarget(rpm: 3000, fan: 0) }
        #expect(!smc.wrote("F0Tg"))
    }

    @Test func `targets are clamped to the firmware range`() throws {
        let smc = FakeSMC.appleSilicon()
        try SMCFanControl(smc: smc, modeSwitchAttempts: 2, modeSwitchInterval: 0).setTarget(rpm: 99_999, fan: 0)
        #expect(smc.values["F0Tg"] == 6000)
        #expect(smc.values["F0Md"] == 1)
    }

    @Test(arguments: [Double.nan, .infinity, -1, 2.5, 11])
    func `an unusable fan count is an error, not zero fans`(count: Double) {
        let smc = FakeSMC.appleSilicon()
        smc.values["FNum"] = count
        #expect(throws: SMCError.self) { try SMCFanControl(smc: smc, modeSwitchAttempts: 2, modeSwitchInterval: 0).fanCount() }
    }

    @Test func `a missing fan count is an error`() {
        let smc = FakeSMC.appleSilicon()
        smc.values["FNum"] = nil
        #expect(throws: SMCError.self) { try SMCFanControl(smc: smc, modeSwitchAttempts: 2, modeSwitchInterval: 0).fanCount() }
        // Restoring must not claim success when it can't even count the fans.
        #expect(throws: SMCError.self) { try SMCFanControl(smc: smc, modeSwitchAttempts: 2, modeSwitchInterval: 0).restoreAutomatic() }
    }
}

/// R1, R2: the helper's bookkeeping for "who owns the fans".
@Suite("FanControlSession")
struct FanControlSessionTests {
    let start = Date(timeIntervalSince1970: 0)

    @Test func `a failed restore is reported and keeps the session in control`() throws {
        let smc = FakeSMC.appleSilicon()
        let session = FanControlSession(fans: SMCFanControl(smc: smc, modeSwitchAttempts: 2, modeSwitchInterval: 0), watchdogTimeout: 20)
        try session.setTarget(rpm: 3000, fan: 0, at: start)

        smc.ignoring = ["F0Md"]
        #expect(throws: SMCError.self) { try session.restore() }
        #expect(session.isControlling)
    }

    @Test func `the watchdog keeps retrying a failed restore`() throws {
        let smc = FakeSMC.appleSilicon()
        let session = FanControlSession(fans: SMCFanControl(smc: smc, modeSwitchAttempts: 2, modeSwitchInterval: 0), watchdogTimeout: 20)
        try session.setTarget(rpm: 3000, fan: 0, at: start)

        smc.ignoring = ["F0Md"]
        #expect(session.checkWatchdog(at: start + 25) == .restoreFailed)
        #expect(session.isControlling)

        smc.ignoring = []
        #expect(session.checkWatchdog(at: start + 30) == .returnedFans)
        #expect(!session.isControlling)
        #expect(smc.values["F0Md"] == 0)
    }

    @Test func `a successful restore ends control`() throws {
        let smc = FakeSMC.appleSilicon()
        let session = FanControlSession(fans: SMCFanControl(smc: smc, modeSwitchAttempts: 2, modeSwitchInterval: 0), watchdogTimeout: 20)
        try session.setTarget(rpm: 3000, fan: 0, at: start)
        try session.restore()
        #expect(!session.isControlling)
        #expect(smc.values["F0Md"] == 0)
    }

    @Test func `a failed target write hands the fans back`() throws {
        let smc = FakeSMC.appleSilicon()
        let session = FanControlSession(fans: SMCFanControl(smc: smc, modeSwitchAttempts: 2, modeSwitchInterval: 0), watchdogTimeout: 20)
        try session.setTarget(rpm: 3000, fan: 0, at: start)

        smc.rejecting = ["F1Tg"]
        #expect(throws: (any Error).self) { try session.setTarget(rpm: 3000, fan: 1, at: start + 1) }
        #expect(smc.values["F0Md"] == 0)
        #expect(smc.values["F1Md"] == 0)
        #expect(!session.isControlling)
    }

    @Test func `failed writes are not a heartbeat`() throws {
        let smc = FakeSMC.appleSilicon()
        let session = FanControlSession(fans: SMCFanControl(smc: smc, modeSwitchAttempts: 2, modeSwitchInterval: 0), watchdogTimeout: 20)
        try session.setTarget(rpm: 3000, fan: 0, at: start)

        // Writes keep failing and the hand-back fails too, so the session stays in control.
        smc.rejecting = ["F0Tg"]
        smc.ignoring = ["F0Md"]
        for second in stride(from: 5.0, through: 20, by: 5) {
            _ = try? session.setTarget(rpm: 3000, fan: 0, at: start + second)
        }
        #expect(session.isControlling)

        smc.ignoring = []
        session.checkWatchdog(at: start + 21)
        #expect(!session.isControlling)
    }

    @Test func `the watchdog leaves a healthy session alone`() throws {
        let smc = FakeSMC.appleSilicon()
        let session = FanControlSession(fans: SMCFanControl(smc: smc, modeSwitchAttempts: 2, modeSwitchInterval: 0), watchdogTimeout: 20)
        try session.setTarget(rpm: 3000, fan: 0, at: start)
        #expect(session.checkWatchdog(at: start + 10) == .idle)
        #expect(session.isControlling)
        #expect(smc.values["F0Md"] == 1)
    }

    // MARK: Start-up restore (helper wave 3). A fresh session has never written, as at helper start.

    @Test func `a fresh session's restore returns leftover manual fans and Ftst`() throws {
        let smc = FakeSMC.appleSilicon()
        smc.values["F0Md"] = 1
        smc.values["F1Md"] = 1
        smc.values["Ftst"] = 1
        let session = FanControlSession(fans: SMCFanControl(smc: smc, modeSwitchAttempts: 2, modeSwitchInterval: 0), watchdogTimeout: 20)

        try session.restore()

        #expect(smc.values["F0Md"] == 0)
        #expect(smc.values["F1Md"] == 0)
        #expect(smc.values["Ftst"] == 0)
        #expect(!session.isControlling)
    }

    @Test func `restoring an already automatic SMC succeeds and stays automatic`() throws {
        let smc = FakeSMC.appleSilicon()
        let session = FanControlSession(fans: SMCFanControl(smc: smc, modeSwitchAttempts: 2, modeSwitchInterval: 0), watchdogTimeout: 20)

        try session.restore()
        try session.restore()

        #expect(["F0Md", "F1Md", "Ftst"].allSatisfy { smc.values[$0] == 0 })
        #expect(!session.isControlling)
    }

    @Test func `restore clears Ftst when only one fan was left manual`() throws {
        let smc = FakeSMC.appleSilicon()
        smc.values["F1Md"] = 1
        smc.values["Ftst"] = 1
        let session = FanControlSession(fans: SMCFanControl(smc: smc, modeSwitchAttempts: 2, modeSwitchInterval: 0), watchdogTimeout: 20)

        try session.restore()

        #expect(smc.values["F0Md"] == 0)
        #expect(smc.values["F1Md"] == 0)
        #expect(smc.values["Ftst"] == 0)
    }

    @Test func `restore clears the forced bits on a Mac without mode keys`() throws {
        let smc = FakeSMC([
            "FNum": 2, "FS! ": 3,
            "F0Ac": 2000, "F0Mn": 1200, "F0Mx": 6000, "F0Tg": 2000,
            "F1Ac": 2100, "F1Mn": 1200, "F1Mx": 6000, "F1Tg": 2100,
        ])
        let session = FanControlSession(fans: SMCFanControl(smc: smc, modeSwitchAttempts: 2, modeSwitchInterval: 0), watchdogTimeout: 20)

        try session.restore()

        #expect(smc.values["FS! "] == 0)
        #expect(!session.isControlling)
    }

    @Test func `a failed restore on a fresh session is retried by the watchdog until it works`() throws {
        let smc = FakeSMC.appleSilicon()
        smc.values["F0Md"] = 1
        smc.values["Ftst"] = 1
        let session = FanControlSession(fans: SMCFanControl(smc: smc, modeSwitchAttempts: 2, modeSwitchInterval: 0), watchdogTimeout: 20)

        smc.ignoring = ["F0Md"]
        #expect(throws: SMCError.self) { try session.restore() }
        #expect(session.isControlling)
        #expect(session.checkWatchdog(at: start) == .restoreFailed)
        #expect(session.isControlling)

        smc.ignoring = []
        #expect(session.checkWatchdog(at: start + 5) == .returnedFans)
        #expect(smc.values["F0Md"] == 0)
        #expect(smc.values["Ftst"] == 0)
        #expect(!session.isControlling)

        // After success no further restore happens without a new cause.
        let writesAfterSuccess = smc.writes.count
        #expect(session.checkWatchdog(at: start + 10) == .idle)
        #expect(smc.writes.count == writesAfterSuccess)
    }

    @Test func `an invalid fan index is rejected before anything is written`() {
        let smc = FakeSMC.appleSilicon()
        let session = FanControlSession(fans: SMCFanControl(smc: smc, modeSwitchAttempts: 2, modeSwitchInterval: 0), watchdogTimeout: 20)
        #expect(throws: (any Error).self) { try session.setTarget(rpm: 3000, fan: 7, at: start) }
        #expect(smc.writes.isEmpty)
        #expect(!session.isControlling)
    }
}
