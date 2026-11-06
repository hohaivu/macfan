import Foundation
import Testing
@testable import MacFanCore

private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func cpu(_ celsius: Double, at seconds: TimeInterval, throttled: Bool = false,
                 recorder: inout HotMomentRecorder) -> HotMoment? {
    recorder.update(Fixtures.snapshot([Fixtures.reading(celsius, id: "cpu")], at: start.addingTimeInterval(seconds)),
                    isThrottling: throttled)
}

@Suite("Hot moments")
struct HotMomentTests {
    @Test func `a short spike is not a moment`() {
        var recorder = HotMomentRecorder()
        for t in stride(from: 0.0, through: 20, by: 2) { #expect(cpu(95, at: t, recorder: &recorder) == nil) }
        #expect(recorder.inProgress == nil)
        for t in stride(from: 22.0, through: 400, by: 2) { #expect(cpu(60, at: t, recorder: &recorder) == nil) }
        #expect(recorder.wantsActivity == false)
    }

    @Test func `sustained heat is recorded from its first reading`() throws {
        var recorder = HotMomentRecorder()
        var finished: HotMoment?
        for t in stride(from: 0.0, through: 60, by: 2) { _ = cpu(t == 40 ? 99 : 95, at: t, recorder: &recorder) }
        #expect(recorder.inProgress?.start == start)
        for t in stride(from: 62.0, through: 300, by: 2) {
            if let moment = cpu(60, at: t, recorder: &recorder) { finished = moment }
        }
        let moment = try #require(finished)
        #expect(moment.start == start)
        #expect(moment.end == start.addingTimeInterval(60), "Ends at the last hot reading, not after the cool-down")
        #expect(moment.peakCelsius == 99)
        #expect(moment.peakCategory == .cpu)
        #expect(recorder.inProgress == nil)
    }

    @Test func `heat that returns during the cool-down stays one moment`() throws {
        var recorder = HotMomentRecorder()
        var moments: [HotMoment] = []
        func run(_ celsius: Double, _ range: StrideThrough<Double>) {
            for t in range { if let m = cpu(celsius, at: t, recorder: &recorder) { moments.append(m) } }
        }
        run(95, stride(from: 0, through: 40, by: 2))
        run(60, stride(from: 42, through: 100, by: 2))
        run(95, stride(from: 102, through: 140, by: 2))
        run(60, stride(from: 142, through: 400, by: 2))
        #expect(moments.count == 1)
        #expect(try #require(moments.first).end == start.addingTimeInterval(140))
    }

    @Test func `apps aren't sampled while cooling down`() {
        var recorder = HotMomentRecorder()
        for t in stride(from: 0.0, through: 40, by: 2) { _ = cpu(95, at: t, recorder: &recorder) }
        #expect(recorder.wantsActivity)
        _ = cpu(60, at: 42, recorder: &recorder)
        #expect(!recorder.wantsActivity)
        #expect(recorder.inProgress != nil, "Still the same moment until the cool-down ends")
        _ = cpu(95, at: 44, recorder: &recorder)
        #expect(recorder.wantsActivity)
    }

    @Test func `throttling counts even when temperatures look fine`() throws {
        var recorder = HotMomentRecorder()
        var finished: HotMoment?
        for t in stride(from: 0.0, through: 60, by: 2) { _ = cpu(70, at: t, throttled: true, recorder: &recorder) }
        for t in stride(from: 62.0, through: 300, by: 2) {
            if let moment = cpu(60, at: t, recorder: &recorder) { finished = moment }
        }
        #expect(try #require(finished).throttledSeconds == 60)
    }

    @Test func `sleep ends a moment where the readings stopped`() throws {
        var recorder = HotMomentRecorder()
        for t in stride(from: 0.0, through: 60, by: 2) { _ = cpu(95, at: t, recorder: &recorder) }
        let moment = try #require(cpu(95, at: 60 + 3600, recorder: &recorder))
        #expect(moment.end == start.addingTimeInterval(60))
    }

    @Test func `culprits are average shares, without the macOS remainder`() throws {
        var recorder = HotMomentRecorder()
        let busy = AppActivity(id: "/Applications/Busy.app", name: "Busy", bundlePath: "/Applications/Busy.app", cpuPercent: 400, cores: 10)
        let blip = AppActivity(id: "/usr/bin/blip", name: "blip", bundlePath: nil, cpuPercent: 10, cores: 10)
        let system = AppActivity(id: AppActivity.systemID, name: "macOS", bundlePath: nil, cpuPercent: 900, cores: 10)
        recorder.record([busy])  // nothing is hot yet: ignored
        _ = cpu(95, at: 0, recorder: &recorder)
        recorder.record([busy, blip, system])
        recorder.record([system])
        for t in stride(from: 2.0, through: 40, by: 2) { _ = cpu(95, at: t, recorder: &recorder) }
        let culprits = try #require(recorder.inProgress).culprits
        #expect(culprits.map(\.name) == ["Busy"], "blip averages 0.5%, under the 1% floor")
        #expect(culprits.first?.share == 20, "40% in one of two samples")
    }
}

private func coolingSnapshot(cpu: Double, air: Double, rpm: Double?, manual: Bool = false, at seconds: TimeInterval) -> HardwareSnapshot {
    let airSensor = Sensor(id: "smc.TaLP", name: "Airflow Left", category: .enclosure, source: .smc, rawKey: "TaLP", isIdentified: true)
    let pipe = Sensor(id: "smc.Th0H", name: "Heat Pipe", category: .enclosure, source: .smc, rawKey: "Th0H", isIdentified: true)
    let fans = rpm.map { [FanStatus(index: 0, name: "Fan", currentRPM: $0, minimumRPM: 1200, maximumRPM: 6000, targetRPM: nil, isManual: manual)] } ?? []
    return HardwareSnapshot(
        date: start.addingTimeInterval(seconds),
        readings: [Fixtures.reading(cpu, id: "cpu"), SensorReading(sensor: airSensor, celsius: air), SensorReading(sensor: pipe, celsius: 20)],
        fans: fans, battery: nil
    )
}

@Suite("Cooling health")
struct CoolingHealthTests {
    private func run(_ sampler: inout CoolingSampler, from: TimeInterval, to: TimeInterval,
                     load: (TimeInterval) -> Double = { _ in 10 }, manual: Bool = false,
                     controller: CoolingController? = .macOS) -> [CoolingSample] {
        stride(from: from, through: to, by: 2).compactMap {
            sampler.add(coolingSnapshot(cpu: 70, air: 35, rpm: 2000, manual: manual, at: $0), load: load($0), controller: controller)
        }
    }

    private let curve = CoolingController.curve(CurvePreset.balanced.curve!, source: .hottestCPU)

    @Test func `waits for temperatures to settle after starting`() {
        var sampler = CoolingSampler()
        #expect(run(&sampler, from: 0, to: 298).isEmpty)
        let samples = run(&sampler, from: 300, to: 480)
        #expect(samples.count == 2, "The first settled minute only sets the comparison")
        #expect(samples.first?.rise == 35, "CPU minus the airflow sensor; heat pipes don't count as air")
        #expect(samples.first?.fanRPM == 2000)
        #expect(samples.first?.load == 10)
    }

    @Test func `skips a minute whose workload moved from the one before`() {
        var sampler = CoolingSampler()
        _ = run(&sampler, from: 0, to: 298)
        #expect(run(&sampler, from: 300, to: 480, load: { $0 < 420 ? 10 : 30 }).count == 1, "Only the steady 10 W minute")
    }

    @Test func `second-to-second spikes average out`() {
        var sampler = CoolingSampler()
        _ = run(&sampler, from: 0, to: 298)
        let samples = run(&sampler, from: 300, to: 480, load: { $0.truncatingRemainder(dividingBy: 4) == 0 ? 25 : 5 })
        #expect(samples.count == 2)
    }

    @Test func `skips minutes when nobody comparable is choosing fan speeds`() {
        var sampler = CoolingSampler()
        _ = run(&sampler, from: 0, to: 298)
        #expect(run(&sampler, from: 300, to: 420, manual: true).isEmpty, "Another app set the fans to manual")
        #expect(run(&sampler, from: 422, to: 900, controller: nil).isEmpty, "MacFan is running a fixed speed")
    }

    @Test func `learns under a Smart Curve, whose fans are manual`() {
        var sampler = CoolingSampler()
        _ = run(&sampler, from: 0, to: 298, manual: true, controller: curve)
        let samples = run(&sampler, from: 300, to: 480, manual: true, controller: curve)
        #expect(samples.count == 2)
        #expect(samples.allSatisfy { $0.controller == curve })
    }

    @Test func `settles again after the controller changes`() {
        var sampler = CoolingSampler()
        _ = run(&sampler, from: 0, to: 420)
        #expect(run(&sampler, from: 422, to: 720, manual: true, controller: curve).isEmpty)
        #expect(run(&sampler, from: 722, to: 960, manual: true, controller: curve).count == 2)
    }

    @Test func `modes map to what Cooling Health learns under`() {
        var settings = CoolingSettings()
        #expect(settings.learningController == .macOS)
        settings.mode = .curve
        #expect(settings.learningController == curve)
        settings.mode = .fixed
        #expect(settings.learningController == nil)
        settings.mode = .max
        #expect(settings.learningController == nil)
    }

    @Test func `log keeps each controller apart`() {
        var log = CoolingLog()
        let other = CoolingController.curve(CurvePreset.quiet.curve!, source: .hottestCPU)
        for minute in 0..<10 {
            log.add(CoolingSample(date: start.addingTimeInterval(Double(minute) * 60), load: 10, rise: 30, fanRPM: 2000), kind: .watts)
            log.add(CoolingSample(date: start.addingTimeInterval(Double(minute) * 60), load: 10, rise: 25, fanRPM: 3000, controller: curve), kind: .watts)
        }
        #expect(log.entries.count == 2)
        #expect(log.daysCollected(under: .macOS) == 1)
        #expect(log.daysCollected(under: curve) == 1)
        #expect(log.daysCollected(under: other) == 0)
        #expect(log.hasLearnedOtherCurve(than: other))
        #expect(!log.hasLearnedOtherCurve(than: curve), "macOS's minutes aren't another curve")
    }

    @Test func `entries saved before controllers were tracked belong to macOS`() throws {
        let json = #"{"day":0,"band":2,"minutes":12,"riseTotal":360,"rpmTotal":24000,"rpmMinutes":12}"#
        let entry = try JSONDecoder().decode(CoolingLog.Entry.self, from: Data(json.utf8))
        #expect(entry.controller == CoolingController.macOS.key)
    }

    @Test func `settles again after the Mac sleeps`() {
        var sampler = CoolingSampler()
        _ = run(&sampler, from: 0, to: 420)
        #expect(run(&sampler, from: 4000, to: 4200).isEmpty)
    }

    @Test func `log condenses samples per day and band`() {
        var log = CoolingLog()
        let day = start
        log.add(CoolingSample(date: day, load: 12, rise: 30, fanRPM: 2000), kind: .watts)
        log.add(CoolingSample(date: day.addingTimeInterval(60), load: 14, rise: 34, fanRPM: nil), kind: .watts)
        log.add(CoolingSample(date: day.addingTimeInterval(120), load: 26, rise: 50, fanRPM: 3000), kind: .watts)
        #expect(log.entries.count == 2)
        let band = log.entries.first { $0.band == 2 }
        #expect(band?.minutes == 2)
        #expect(band?.averageRise == 32)
        #expect(band?.averageRPM == 2000, "Minutes without fan data don't dilute the fan average")
        #expect(log.daysCollected(under: .macOS, minimumMinutes: 3) == 1)
        #expect(log.daysCollected(under: .macOS, minimumMinutes: 4) == 0)
    }

    @Test func `log keeps four months`() {
        var log = CoolingLog()
        log.add(CoolingSample(date: start, load: 10, rise: 30, fanRPM: nil), kind: .watts)
        log.add(CoolingSample(date: start.addingTimeInterval(200 * 24 * 3600), load: 10, rise: 30, fanRPM: nil), kind: .watts)
        #expect(log.entries.count == 1)
    }

    @Test func `cpu share meter measures between readings`() {
        var meter = CPUShareMeter()
        #expect(meter.update(CPULoad(busyTicks: 0, totalTicks: 0)) == nil)
        #expect(meter.update(CPULoad(busyTicks: 25, totalTicks: 100)) == 25)
    }
}

@Suite("Insights storage")
struct InsightsStorageTests {
    @Test func `a 0.3.x cooling log is discarded`() throws {
        let json = #"{"loadKind":"watts","entries":[{"day":0,"band":2,"controller":"macOS","minutes":12,"riseTotal":360,"rpmTotal":24000,"rpmMinutes":12}]}"#
        let log = try JSONDecoder().decode(CoolingLog.self, from: Data(json.utf8))
        #expect(log.entries.isEmpty)
        #expect(log.loadKind == nil)
    }

    @Test func `a 0.3.x insights file keeps its moments and loses only the cooling log`() throws {
        let moment = HotMoment(start: start, end: start.addingTimeInterval(90), peakCelsius: 95, peakSensor: "CPU 3", peakCategory: .cpu,
                               throttledSeconds: 30, culprits: [])
        let momentJSON = String(decoding: try JSONEncoder().encode(moment), as: UTF8.self)
        let cooling = #"{"loadKind":"watts","entries":[{"day":0,"band":2,"controller":"macOS","minutes":12,"riseTotal":360,"rpmTotal":24000,"rpmMinutes":12}]}"#
        let json = "{\"moments\":[\(momentJSON)],\"cooling\":\(cooling)}"

        let data = try JSONDecoder().decode(InsightsData.self, from: Data(json.utf8))
        #expect(data.moments == [moment])
        #expect(data.cooling.entries.isEmpty)
        #expect(data.cooling.loadKind == nil)
    }

    @Test func `moments older than a month are dropped`() {
        var insights = InsightsData()
        let old = HotMoment(start: start, end: start, peakCelsius: 95, peakSensor: "CPU", peakCategory: .cpu, throttledSeconds: 0, culprits: [])
        let new = HotMoment(start: start.addingTimeInterval(40 * 24 * 3600), end: start.addingTimeInterval(40 * 24 * 3600 + 60),
                            peakCelsius: 96, peakSensor: "CPU", peakCategory: .cpu, throttledSeconds: 0, culprits: [])
        insights.add(old)
        insights.add(new)
        #expect(insights.moments == [new])
    }

    @Test func `round trips through the file, and a broken file reads as empty`() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)/insights.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let file = InsightsFile(url: url)
        var insights = InsightsData()
        insights.add(HotMoment(start: start, end: start.addingTimeInterval(90), peakCelsius: 95, peakSensor: "CPU 3", peakCategory: .cpu,
                               throttledSeconds: 30, culprits: [.init(id: "/Applications/Xcode.app", name: "Xcode", bundlePath: "/Applications/Xcode.app", share: 41)]))
        insights.cooling.add(CoolingSample(date: start, load: 10, rise: 30, fanRPM: 2000), kind: .watts)
        try file.save(insights)
        #expect(file.load() == insights)

        try Data("not json".utf8).write(to: url)
        #expect(file.load() == InsightsData())
    }
}
