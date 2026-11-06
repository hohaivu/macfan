import AppKit
import MacFanCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.showDetail) private var showDetail
    @Binding var destination: Destination

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                StatusHero(status: model.status, thermalState: model.thermalState, busiestApp: model.busiestApp)

                if !model.snapshot.fans.isEmpty {
                    FansOverviewCard(onManage: { destination = .fans })
                }

                // Only parts whose temperature is worth acting on. Everything else is in Sensors.
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 200), spacing: Theme.Spacing.l)],
                    spacing: Theme.Spacing.l
                ) {
                    ForEach(model.summaries.filter(\.category.isSafetyRelevant)) { summary in
                        Button { showDetail(.category(summary.category)) } label: {
                            CategoryCard(
                                summary: summary,
                                history: model.history.values(for: HistoryStore.key(for: summary.category))
                            )
                        }
                        .buttonStyle(PressableButtonStyle())
                        .help("Show history")
                    }
                    if let watts = model.snapshot.systemPower {
                        Button { showDetail(.systemPower) } label: {
                            PowerCard(watts: watts, battery: model.snapshot.battery,
                                      history: model.history.values(for: HistoryStore.systemPowerKey))
                        }
                        .buttonStyle(PressableButtonStyle())
                        .help("Show history")
                    }
                }

                ActivityCard()

                Button {
                    destination = .sensors
                } label: {
                    Label("All \(model.visibleReadings.count) sensors", systemImage: "arrow.right")
                        .labelStyle(TrailingIconLabelStyle())
                }
                .buttonStyle(.link)
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Overview")
        .whileVisible { await model.watchActivity() }
    }
}

/// The answer to "is my Mac OK?", big and first.
private struct StatusHero: View {
    let status: ThermalStatus
    let thermalState: ProcessInfo.ThermalState
    let busiestApp: AppActivity?

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.l) {
            Image(systemName: status.level.symbol)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(status.level.tint)
                .frame(width: 60, height: 60)
                .background(status.level.tint.opacity(0.12), in: .circle)
                .contentTransition(.symbolEffect(.replace))

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(status.headline)
                    .font(.largeTitle.weight(.bold))
                Text(status.detail)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Warm or worse is when "why?" comes up; answer it with the app doing the work.
                if status.level >= .warm, let busiestApp {
                    Label {
                        Text("Busiest app: \(busiestApp.displayName), \(CPUPercent.format(busiestApp.shareOfMac)) of the CPU")
                    } icon: {
                        AppIcon(app: busiestApp, size: 16)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: Theme.Spacing.l)

            VStack(alignment: .trailing, spacing: Theme.Spacing.xxs) {
                Text("Thermal pressure")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(status.pressure)
                    .font(.headline)
            }
            .help("How much macOS is limiting performance to manage heat. Nominal means not at all.")
        }
        .fluidAnimation(value: status)
        .accessibilityElement(children: .combine)
    }
}

private struct CategoryCard: View {
    let summary: CategorySummary
    let history: [Double]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                HStack {
                    Label(summary.category.title, systemImage: summary.category.symbol)
                        .font(.headline)
                    Spacer()
                    LevelBadge(level: summary.level)
                }

                TemperatureText(celsius: summary.hottest.celsius, font: .system(size: 40, weight: .semibold, design: .rounded))

                Sparkline(values: history, tint: summary.level.tint)
                    .frame(height: 32)

                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(.rect(cornerRadius: Theme.Radius.card))
        .accessibilityElement(children: .combine)
    }

    private var caption: String {
        summary.count == 1
            ? summary.hottest.sensor.name
            : String(localized: "Hottest: \(summary.hottest.sensor.name) · \(summary.count) sensors")
    }
}

/// Same shape as the temperature cards, so the grid reads as one set.
private struct PowerCard: View {
    let watts: Double
    let battery: BatteryInfo?
    let history: [Double]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Label("Power Draw", systemImage: "bolt")
                    .font(.headline)

                Text(Watts.format(watts))
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()

                Sparkline(values: history, tint: .yellow, minimumSpan: 10)
                    .frame(height: 32)

                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(.rect(cornerRadius: Theme.Radius.card))
        .accessibilityElement(children: .combine)
    }

    private var caption: String {
        guard let battery else { return String(localized: "Whole system") }
        if battery.isPluggedIn {
            return battery.adapterWatts.map { String(localized: "From a \($0) W adapter") } ?? String(localized: "On power adapter")
        }
        return battery.minutesRemaining.map { String(localized: "On battery · \(Duration.seconds($0 * 60).formatted(.units(allowed: [.hours, .minutes], width: .narrow))) left") }
            ?? String(localized: "On battery")
    }
}

/// "Why is my Mac warm?" — the apps doing the work right now.
private struct ActivityCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                HStack {
                    Label("Using the CPU", systemImage: "gauge.with.dots.needle.33percent")
                        .font(.headline)
                    if let busy = model.cpuBusy {
                        Text("Mac is \(CPUPercent.format(busy)) busy")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer()
                    Button("Activity Monitor") {
                        NSWorkspace.shared.open(URL(filePath: "/System/Applications/Utilities/Activity Monitor.app"))
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                }

                if model.topApps.isEmpty {
                    Text("Measuring…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                } else {
                    VStack(spacing: Theme.Spacing.s) {
                        ForEach(model.topApps) { app in
                            AppActivityRow(app: app)
                        }
                    }
                }

                Text("Share of your Mac's total processing power. macOS reports details only for your own apps; the rest is counted under macOS.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct AppActivityRow: View {
    let app: AppActivity

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            AppIcon(app: app, size: 20)
            Text(app.displayName).lineLimit(1)
            Spacer(minLength: Theme.Spacing.s)
            // The whole bar is the whole Mac, so lengths add up the way the numbers do.
            Capsule()
                .fill(.quaternary)
                .frame(width: 80, height: 6)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(tint)
                        .frame(width: 80 * min(app.shareOfMac / 100, 1), height: 6)
                }
            Text(CPUPercent.format(app.shareOfMac))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 48, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch app.shareOfMac {
        case 50...: .red
        case 25...: .orange
        default: .accentColor
        }
    }
}

/// An app's Finder icon, or a generic one for command-line tools.
struct AppIcon: View {
    private let bundlePath: String?
    private let fallbackSymbol: String
    let size: CGFloat

    init(app: AppActivity, size: CGFloat) {
        self.bundlePath = app.bundlePath
        self.fallbackSymbol = app.isSystem ? "applelogo" : (app.isSystemComponent ? "gearshape" : "terminal")
        self.size = size
    }

    init(culprit: HotMoment.Culprit, size: CGFloat) {
        self.bundlePath = culprit.bundlePath
        self.fallbackSymbol = culprit.isSystemComponent ? "gearshape" : "terminal"
        self.size = size
    }

    var body: some View {
        Group {
            if let bundlePath {
                Image(nsImage: Self.icon(forFile: bundlePath))
                    .resizable()
            } else {
                Image(systemName: fallbackSymbol)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// The list refreshes every few seconds; looking icons up each time would be wasted work.
    private static var icons: [String: NSImage] = [:]

    private static func icon(forFile path: String) -> NSImage {
        if let icon = icons[path] { return icon }
        if icons.count > 64 { icons.removeAll() }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }
}

extension AppActivity {
    var displayName: String {
        isSystem ? String(localized: "macOS & system services") : name
    }
}

enum CPUPercent {
    /// "42%", or "<1%" for a sliver that would otherwise read as nothing.
    static func format(_ percent: Double) -> String {
        percent > 0 && percent < 0.5 ? "<1%" : "\(Int(percent.rounded()))%"
    }
}

private struct FansOverviewCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.showDetail) private var showDetail
    let onManage: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                HStack {
                    Label("Fans", systemImage: "fan")
                        .font(.headline)
                    Spacer()
                    CoolingModeTag()
                    Button("Change…", action: onManage)
                }

                HStack(spacing: Theme.Spacing.xxl) {
                    ForEach(model.snapshot.fans) { fan in
                        Button { showDetail(.fan(index: fan.index)) } label: {
                            HStack(spacing: Theme.Spacing.m) {
                                FanGauge(load: fan.load)
                                    .frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                                    Text(fan.name).font(.subheadline).foregroundStyle(.secondary)
                                    RPMText(rpm: fan.currentRPM, font: .title3.weight(.semibold))
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(PressableButtonStyle())
                        .help("Show history")
                        .accessibilityElement(children: .combine)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// Who is in charge of the fans right now, in a word.
struct CoolingModeTag: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Text(Self.text(for: model.cooling.state, mode: model.preferences.cooling.mode))
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.vertical, Theme.Spacing.xxs + 1)
            .background(.quaternary, in: .capsule)
    }

    static func text(for state: FanControlEngine.State, mode: CoolingMode) -> LocalizedStringResource {
        switch state {
        case .system: "Managed by macOS"
        case .emergency: "Full speed (safety)"
        case .noData: "macOS (no data)"
        case .controlling: mode.title
        case .needsHelper: "Needs setup"
        case .failed: "Error"
        }
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            configuration.title
            configuration.icon
        }
    }
}
