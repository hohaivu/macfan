import AppKit
import IOKit.ps
import MacFanCore
import Observation
import os

/// The single source of truth for the UI. Polls the hardware, drives fan control,
/// alerts and logging, and reacts to sleep/wake and termination.
@Observable
final class AppModel {
    static let shared = AppModel()

    let preferences = Preferences()
    let helper = HelperManager()
    let updates = UpdateManager()
    let cooling: FanControlEngine

    /// The latest readings. Always current for code that asks; views reading it are only
    /// refreshed while some window or the menu bar panel is on screen (see `keepDisplayCurrent`).
    var snapshot: HardwareSnapshot {
        _ = displayRevision
        return liveSnapshot
    }

    /// Like `snapshot`: always recorded, but only pushed to views while they can be seen.
    var history: HistoryStore {
        _ = displayRevision
        return liveHistory
    }
    /// Hot moments and cooling history. Like `snapshot`, only pushed to views while visible.
    var insights: InsightsData {
        _ = displayRevision
        return liveInsights
    }

    /// The hot moment happening right now, if any.
    var hotMomentInProgress: HotMoment? {
        _ = displayRevision
        return hotMoments.inProgress
    }

    private(set) var thermalState = ProcessInfo.processInfo.thermalState
    private(set) var hasStarted = false
    /// Busiest apps, busiest first. Only kept current while a view showing them is on screen.
    private(set) var topApps: [AppActivity] = []
    /// How busy the whole Mac is, 0…100. Kept current alongside `topApps`.
    private(set) var cpuBusy: Double?
    /// What the menu bar shows. Assigned only when it changes, so the status item isn't
    /// redrawn on every refresh.
    private(set) var menuBarContent = MenuBarContent(symbol: "thermometer.medium", text: nil)

    @ObservationIgnored private var liveSnapshot = HardwareSnapshot.empty
    @ObservationIgnored private var liveHistory = HistoryStore()
    /// Bumped on each refresh while UI is visible. Hidden SwiftUI views still re-render and
    /// re-measure when what they read changes, so readings only reach views through this.
    private var displayRevision = 0
    @ObservationIgnored private var visibleViews = 0

    @ObservationIgnored private var liveInsights = InsightsData()
    @ObservationIgnored private var hotMoments = HotMomentRecorder()
    @ObservationIgnored private var coolingSampler = CoolingSampler()
    @ObservationIgnored private var cpuShare = CPUShareMeter()
    @ObservationIgnored private let insightsFile = InsightsFile()
    @ObservationIgnored private var insightsChanged = false
    @ObservationIgnored private var lastInsightsSave = Date()

    @ObservationIgnored private let monitor = HardwareMonitor()
    @ObservationIgnored private let activity = ActivityMonitor()
    @ObservationIgnored private var activityWatchers = 0
    @ObservationIgnored private var lastActivitySample = Date.distantPast
    @ObservationIgnored private var powerSourceNotification: CFRunLoopSource?
    @ObservationIgnored private var isOnBattery: Bool?
    @ObservationIgnored private let alerts = AlertCenter()
    @ObservationIgnored private let logger = CSVLogger(directory: CSVLogger.defaultDirectory)
    @ObservationIgnored private let log = Logger(subsystem: "io.github.alvinmr.MacFan", category: "model")
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var pendingSleep: Task<Void, Never>?
    @ObservationIgnored private var lastLogged = Date.distantPast
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        cooling = FanControlEngine(commander: helper)
    }

    var logDirectory: URL { logger.directory }

    // MARK: Lifecycle

    func start() {
        guard loop == nil else { return }
        liveInsights = insightsFile.load()
        observeSystemEvents()
        observePowerSource()
        loop = Task { [weak self] in
            await self?.helper.refresh()
            while let self, !Task.isCancelled {
                await self.tick()
                let interval = self.preferences.refreshInterval
                let sleep = Task { _ = try? await Task.sleep(for: .seconds(interval)) }
                self.pendingSleep = sleep
                await sleep.value
            }
        }
    }

    /// Runs the next tick now instead of waiting — so a mode change takes effect immediately.
    func refreshNow() {
        pendingSleep?.cancel()
    }

    func prepareForTermination() {
        loop?.cancel()
        cooling.shutdown()
        saveInsights()
        Task { await logger.close() }
    }

    // MARK: Derived state

    var summaries: [CategorySummary] {
        snapshot.summaries(includeUnidentified: preferences.showsUnidentifiedSensors)
    }

    var visibleReadings: [SensorReading] {
        snapshot.readings
            .filter { preferences.showsUnidentifiedSensors || $0.sensor.isIdentified }
            .sorted(by: SensorReading.displayOrder)
    }

    var status: ThermalStatus {
        ThermalStatus(snapshot: snapshot, thermalState: thermalState, hasStarted: hasStarted)
    }

    /// What the menu bar shows: the chosen sensor, else the hottest CPU.
    var menuBarReading: SensorReading? {
        preferences.menuBarSensorID.flatMap(snapshot.reading(id:)) ?? snapshot.hottest(in: [.cpu]) ?? snapshot.hottest()
    }

    var fastestFanRPM: Double? {
        snapshot.fans.map(\.currentRPM).max()
    }

    /// The app most worth mentioning when the Mac is warm: busy enough to matter (half a
    /// core or more), and something the user could quit, so never macOS itself.
    var busiestApp: AppActivity? {
        topApps.first { !$0.isSystemComponent && $0.cpuPercent >= 50 }
    }

    func updateMenuBarContent() {
        let reading = menuBarReading
        let temperature = reading.map { preferences.unit.format($0.celsius) }
        let rpm = fastestFanRPM.map { Int($0.rounded()).formatted() }
        let content = switch preferences.menuBarDisplay {
        case .temperature: MenuBarContent(symbol: (reading?.level ?? .cool).symbol, text: temperature)
        case .fanSpeed: MenuBarContent(symbol: "fan", text: rpm ?? temperature)
        case .both: MenuBarContent(symbol: (reading?.level ?? .cool).symbol,
                                   text: [temperature, rpm].compactMap { $0 }.joined(separator: " · "))
        case .iconOnly: MenuBarContent(symbol: (reading?.level ?? .cool).symbol, text: nil)
        }
        if content != menuBarContent { menuBarContent = content }
    }

    // MARK: Visibility

    /// Keeps views supplied with fresh readings for as long as the calling task runs. Use from
    /// `whileVisible` at the root of each window, so nothing off screen is recomputed.
    func keepDisplayCurrent() async {
        visibleViews += 1
        // Catch up at once: readings kept arriving while nothing was shown.
        displayRevision &+= 1
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        visibleViews -= 1
    }

    // MARK: App activity

    /// Keeps `topApps` current for as long as the calling task runs. Use from `whileVisible`
    /// on views that show it, so MacFan only walks the process list while someone is looking.
    func watchActivity() async {
        activityWatchers += 1
        if activityWatchers == 1 {
            lastActivitySample = .distantPast
            await sampleActivity()
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        activityWatchers -= 1
        if activityWatchers == 0 {
            topApps = []
            cpuBusy = nil
        }
    }

    /// Walks the process list when a visible view shows the result, or a hot moment may be
    /// under way. Never otherwise.
    private func sampleActivity() async {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastActivitySample)
        // Process CPU time is cumulative, so sampling less often loses nothing but latency.
        guard elapsed >= (activityWatchers > 0 ? 3.5 : 10) else { return }
        // After a long pause the previous totals would average over minutes; start afresh.
        if elapsed > 30 { await activity.reset() }
        lastActivitySample = now
        guard let apps = await activity.sample(at: now) else { return }
        if activityWatchers > 0 {
            topApps = Array(apps.prefix(5))
            cpuBusy = min(apps.map(\.shareOfMac).reduce(0, +), 100)
        }
        hotMoments.record(apps)
        log.debug("Sampled app activity (\(self.activityWatchers) visible view(s), hot moment: \(self.hotMoments.wantsActivity))")
    }

    // MARK: Tick

    private func tick() async {
        let snapshot = await monitor.snapshot()
        liveSnapshot = snapshot
        liveHistory.record(snapshot)
        thermalState = snapshot.thermalState
        hasStarted = true
        if visibleViews > 0 { displayRevision &+= 1 }

        updateMenuBarContent()
        updateInsights(with: snapshot)
        if activityWatchers > 0 || hotMoments.wantsActivity { await sampleActivity() }

        await cooling.update(settings: preferences.cooling, snapshot: snapshot)
        alerts.evaluate(snapshot, preferences: preferences, unit: preferences.unit)

        if preferences.loggingEnabled, snapshot.date.timeIntervalSince(lastLogged) >= preferences.loggingInterval {
            lastLogged = snapshot.date
            do {
                try await logger.append(snapshot)
            } catch {
                log.error("CSV logging failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Insights

    private func updateInsights(with snapshot: HardwareSnapshot) {
        let isThrottling = thermalState == .serious || thermalState == .critical
        if let moment = hotMoments.update(snapshot, isThrottling: isThrottling) {
            liveInsights.add(moment)
            insightsChanged = true
            saveInsights()
        }

        // Watts where the Mac reports them; otherwise how busy the CPU is.
        let load: Double?
        let kind: CoolingLog.LoadKind
        if let watts = snapshot.systemPower {
            load = watts
            kind = .watts
        } else {
            load = CPULoad.current().flatMap { cpuShare.update($0) }
            kind = .cpuShare
        }
        // macOS has the fans whenever MacFan isn't driving them; an emergency runs full speed, which reveals nothing, like Max.
        let controller: CoolingController? = switch cooling.state {
        case .controlling: preferences.cooling.learningController
        case .emergency: nil
        default: .macOS
        }
        if let sample = coolingSampler.add(snapshot, load: load, controller: controller) {
            liveInsights.cooling.add(sample, kind: kind)
            insightsChanged = true
            log.debug("Cooling sample: load \(sample.load, format: .fixed(precision: 1)), rise \(sample.rise, format: .fixed(precision: 1))")
            // A minute's sample isn't worth a disk write; an hour's are.
            if Date().timeIntervalSince(lastInsightsSave) >= 3600 { saveInsights() }
        }
    }

    private func saveInsights() {
        guard insightsChanged else { return }
        do {
            try insightsFile.save(liveInsights)
            insightsChanged = false
            lastInsightsSave = Date()
        } catch {
            log.error("Saving insights failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func clearHotMoments() {
        liveInsights.clearMoments()
        insightsChanged = true
        displayRevision &+= 1
        saveInsights()
    }

    // MARK: Actions

    func setCoolingMode(_ mode: CoolingMode) {
        preferences.cooling.mode = mode
        refreshNow()
    }

    func setPowerProfilesEnabled(_ enabled: Bool) {
        preferences.powerProfiles.isEnabled = enabled
        if enabled, let isOnBattery {
            setCoolingMode(preferences.powerProfiles.mode(onBattery: isOnBattery))
        }
    }

    func enableAlerts(_ enabled: Bool) async {
        if enabled {
            preferences.alertsEnabled = await alerts.requestAuthorization()
        } else {
            preferences.alertsEnabled = false
        }
    }

    func applyDockIconPreference() {
        NSApp.setActivationPolicy(preferences.showsDockIcon ? .regular : .accessory)
    }

    func rediscoverSensors() {
        Task {
            await monitor.discover()
            refreshNow()
        }
    }

    // MARK: Power source

    private func observePowerSource() {
        powerSourceChanged()
        // Fires on every battery percentage change too; `powerSourceChanged` ignores those.
        guard let source = IOPSNotificationCreateRunLoopSource({ _ in
            MainActor.assumeIsolated { AppModel.shared.powerSourceChanged() }
        }, nil)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSourceNotification = source
    }

    private func powerSourceChanged() {
        guard let onBattery = PowerSource.isOnBattery(), onBattery != isOnBattery else { return }
        let isLaunch = isOnBattery == nil
        isOnBattery = onBattery
        if preferences.powerProfiles.isEnabled {
            setCoolingMode(preferences.powerProfiles.mode(onBattery: onBattery))
        }
        if !isLaunch {
            Task {
                await monitor.invalidateBattery()
                refreshNow()
            }
        }
    }

    // MARK: System events

    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let model = AppModel.shared
                Task { await model.cooling.suspend() }
            }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let model = AppModel.shared
                model.cooling.resume()
                model.refreshNow()
            }
        })
        // Only wakes the pending sleep; an in-flight tick is not pre-empted.
        observers.append(NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.refreshNow() }
        })
        // Picks up approval in System Settings → Login Items as soon as the user comes back.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let model = AppModel.shared
                Task { await model.helper.refresh() }
            }
        })
    }
}

struct MenuBarContent: Equatable {
    let symbol: String
    let text: String?
}
