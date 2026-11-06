import MacFanCore
import SwiftUI

struct FansView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                if model.snapshot.fans.isEmpty && model.hasStarted {
                    ContentUnavailableView(
                        "This Mac has no fans",
                        systemImage: "fan.slash",
                        description: Text("It's cooled passively. MacFan keeps watching temperatures for you.")
                    )
                    .padding(.top, Theme.Spacing.xxl)
                } else {
                    LiveFansSection()
                    ModePicker()
                    CoolingStatusBanner()
                    if model.preferences.cooling.mode.requiresHelper && !model.helper.isReady {
                        HelperSetupCard()
                    }
                    ModeDetail()
                    if model.snapshot.battery != nil {
                        PowerProfilesCard()
                    }
                    SafetyFootnote()
                }
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Fans")
        .task { await model.helper.refresh() }
    }
}

// MARK: - Live fans

private struct LiveFansSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.showDetail) private var showDetail

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: Theme.Spacing.l)], spacing: Theme.Spacing.l) {
            ForEach(model.snapshot.fans) { fan in
                Button { showDetail(.fan(index: fan.index)) } label: { card(for: fan) }
                    .buttonStyle(PressableButtonStyle())
                    .help("Show history")
            }
        }
    }

    private func card(for fan: FanStatus) -> some View {
        Card {
            HStack(spacing: Theme.Spacing.l) {
                FanGauge(load: fan.load, lineWidth: 7)
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(fan.name).font(.headline)
                    RPMText(rpm: fan.currentRPM, font: .title2.weight(.semibold))
                    Text("Range \(Int(fan.minimumRPM).formatted())–\(Int(fan.maximumRPM).formatted()) rpm")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Sparkline(values: model.history.values(for: HistoryStore.key(forFan: fan.index)), minimumSpan: 500)
                    .frame(width: 80, height: 32)
            }
        }
        .contentShape(.rect(cornerRadius: Theme.Radius.card))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Mode picker

private struct ModePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionTitle(title: "Cooling")
            // Four equal columns keep the choices visually equal; none is buried on a second row.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Spacing.m), count: 4), spacing: Theme.Spacing.m) {
                ForEach(CoolingMode.allCases, id: \.self) { mode in
                    ModeCard(mode: mode, isSelected: model.preferences.cooling.mode == mode) {
                        model.setCoolingMode(mode)
                    }
                }
            }
        }
    }
}

private struct ModeCard: View {
    let mode: CoolingMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Image(systemName: mode.symbol)
                    .font(.title2)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(height: 28)
                Text(mode.title).font(.headline)
                Text(mode.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .padding(Theme.Spacing.l)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.1)) : AnyShapeStyle(.background.secondary))
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.separator.opacity(0.6)),
                                  lineWidth: isSelected ? 2 : 0.5)
            }
            .contentShape(.rect(cornerRadius: Theme.Radius.card))
        }
        .buttonStyle(PressableButtonStyle())
        .fluidAnimation(value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Status

/// Explains, in plain words, whenever MacFan isn't doing what the selected mode says.
private struct CoolingStatusBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let content {
            Card {
                Label {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(content.title).font(.headline)
                        Text(content.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: content.symbol)
                        .foregroundStyle(content.tint)
                }
            }
            .transition(.opacity)
        }
    }

    private var content: (title: LocalizedStringKey, detail: String, symbol: String, tint: Color)? {
        guard model.preferences.cooling.mode != .automatic else { return nil }
        switch model.cooling.state {
        case .emergency:
            return ("macOS is cooling your Mac",
                    String(localized: "Something got critically hot, so macOS took over the fans. Your setting resumes once it has cooled down."),
                    "flame", .orange)
        case .noData:
            return ("Waiting for temperature readings",
                    String(localized: "MacFan can't read the temperatures it needs, so macOS is in charge of the fans until it can."),
                    "thermometer.medium.slash", .secondary)
        case .failed(let message):
            return ("Fan control ran into a problem",
                    String(localized: "\(message). MacFan keeps retrying and hands the fans back to macOS whenever it can't apply your setting."),
                    "exclamationmark.triangle.fill", .red)
        case .system, .controlling, .needsHelper:
            return nil
        }
    }
}

// MARK: - Helper setup

private struct HelperSetupCard: View {
    @Environment(AppModel.self) private var model
    @State private var isWorking = false

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: Theme.Spacing.l) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    Text(title).font(.headline)
                    Text("Reading temperatures needs no permission. Changing fan speed does, so MacFan installs a small helper that runs with system privileges. It only accepts commands from MacFan, and hands the fans back to macOS whenever MacFan quits.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if case .unavailable(let message) = model.helper.status {
                        Text(message).font(.callout).foregroundStyle(.orange)
                    }
                    if let error = model.helper.lastError {
                        Text(error).font(.callout).foregroundStyle(.red)
                    }

                    HStack {
                        Button(action: primaryAction) {
                            Text(buttonTitle)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isWorking)

                        if isWorking {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .padding(.top, Theme.Spacing.xs)
                }
            }
        }
    }

    private var title: LocalizedStringKey {
        switch model.helper.status {
        case .requiresApproval: "Allow MacFan in System Settings"
        case .outdated: "Update the fan control helper"
        default: "One-time setup to control fans"
        }
    }

    private var buttonTitle: LocalizedStringKey {
        switch model.helper.status {
        case .requiresApproval: "Open Login Items…"
        case .outdated: "Update Helper"
        case .unavailable: "Try Again"
        default: "Install Helper"
        }
    }

    private func primaryAction() {
        if model.helper.status == .requiresApproval {
            model.helper.openLoginItemsSettings()
            return
        }
        isWorking = true
        Task {
            await model.helper.install()
            isWorking = false
            model.refreshNow()
        }
    }
}

// MARK: - Mode detail

private struct ModeDetail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.preferences.cooling.mode {
        case .automatic:
            EmptyView()
        case .curve:
            CurveSettings()
        case .fixed:
            FixedSpeedSettings()
        case .max:
            Card {
                Label("Every fan runs at its maximum speed. Useful for short, heavy jobs — switch back when you're done.",
                      systemImage: "speaker.wave.3")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct CurveSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences

        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                HStack(alignment: .firstTextBaseline) {
                    Picker("Curve", selection: $preferences.cooling.preset) {
                        ForEach(CurvePreset.allCases, id: \.self) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 360)

                    Spacer()

                    SourcePicker()
                }

                CurveEditor(
                    curve: curveBinding,
                    liveTemperature: model.cooling.curveTemperature
                        ?? preferences.cooling.source.temperature(in: model.snapshot),
                    onBeginEditing: beginCustomEditing
                )
                .frame(height: 280)

                Text(liveSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                if SafetyPolicy.isBelowMinimum(preferences.cooling.activeCurve) {
                    let t90 = preferences.unit.format(90)
                    let t95 = preferences.unit.format(95)
                    Label(
                        String(localized: "This curve is below the safety minimum. MacFan runs the fans at least 50% at \(t90) and 80% at \(t95)."),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                }

                if preferences.cooling.preset == .custom {
                    DisclosureGroup("Exact values") {
                        CurvePointsEditor(curve: $preferences.cooling.customCurve)
                            .padding(.top, Theme.Spacing.s)
                    }
                }
            }
        }
    }

    /// Edits go to the custom curve; the preset curves are fixed.
    private var curveBinding: Binding<FanCurve> {
        Binding {
            preferences.cooling.activeCurve
        } set: { newValue in
            preferences.cooling.customCurve = newValue
            preferences.cooling.preset = .custom
        }
    }

    private func beginCustomEditing() {
        if preferences.cooling.preset != .custom {
            preferences.cooling.customCurve = preferences.cooling.activeCurve
            preferences.cooling.preset = .custom
        }
    }

    private var liveSummary: String {
        let settings = preferences.cooling
        guard let temperature = model.cooling.curveTemperature ?? settings.source.temperature(in: model.snapshot) else {
            return String(localized: "Waiting for a temperature reading…")
        }
        let speed = settings.activeCurve.speed(at: temperature)
        let percent = Int((speed * 100).rounded())
        let degrees = preferences.unit.format(temperature)
        if let fan = model.snapshot.fans.first {
            let rpm = Int(fan.rpm(forSpeed: speed).rounded()).formatted()
            return String(localized: "At \(degrees) the fans run at \(percent)% (about \(rpm) rpm).")
        }
        return String(localized: "At \(degrees) the fans run at \(percent)%.")
    }
}

private struct SourcePicker: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences

        Picker("Follow", selection: $preferences.cooling.source) {
            Text(TemperatureSource.hottestCPU.title).tag(TemperatureSource.hottestCPU)
            Text(TemperatureSource.hottestGPU.title).tag(TemperatureSource.hottestGPU)
            Text(TemperatureSource.hottestOverall.title).tag(TemperatureSource.hottestOverall)
            if case .sensor(let id) = preferences.cooling.source {
                Divider()
                Text(model.snapshot.reading(id: id)?.sensor.name ?? id).tag(preferences.cooling.source)
            }
        }
        .fixedSize()
        .help("The temperature the curve reacts to. Right-click any sensor in Sensors to follow it instead.")
    }
}

/// Keyboard-friendly, precise editing — the same model as dragging.
private struct CurvePointsEditor: View {
    @Binding var curve: FanCurve
    @Environment(Preferences.self) private var preferences

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.xl, verticalSpacing: Theme.Spacing.s) {
            GridRow {
                Text("Point").foregroundStyle(.secondary)
                Text("Temperature").foregroundStyle(.secondary)
                Text("Fan speed").foregroundStyle(.secondary)
            }
            .font(.caption)

            ForEach(curve.points.indices, id: \.self) { index in
                let point = curve.points[index]
                GridRow {
                    Text("\(index + 1)").monospacedDigit()
                    Stepper(value: temperatureBinding(index), step: 1) {
                        Text(preferences.unit.format(point.temperature)).monospacedDigit().frame(minWidth: 44, alignment: .trailing)
                    }
                    Stepper(value: speedBinding(index), in: 0...1, step: 0.05) {
                        Text("\(Int((point.speed * 100).rounded()))%").monospacedDigit().frame(minWidth: 44, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func temperatureBinding(_ index: Int) -> Binding<Double> {
        Binding {
            curve.points[index].temperature
        } set: { value in
            curve.move(pointAt: index, to: CurvePoint(temperature: value, speed: curve.points[index].speed))
        }
    }

    private func speedBinding(_ index: Int) -> Binding<Double> {
        Binding {
            curve.points[index].speed
        } set: { value in
            curve.move(pointAt: index, to: CurvePoint(temperature: curve.points[index].temperature, speed: value))
        }
    }
}

private struct FixedSpeedSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences

        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Speed").font(.headline)
                    Spacer()
                    Text("\(Int((preferences.cooling.fixedSpeed * 100).rounded()))%")
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: preferences.cooling.fixedSpeed))
                }

                Slider(value: $preferences.cooling.fixedSpeed, in: 0...1) {
                    Text("Speed")
                } minimumValueLabel: {
                    Image(systemName: "tortoise")
                } maximumValueLabel: {
                    Image(systemName: "hare")
                } onEditingChanged: { editing in
                    if !editing { model.refreshNow() }
                }
                .labelsHidden()

                if !model.snapshot.fans.isEmpty {
                    Text(rpmSummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private var rpmSummary: String {
        model.snapshot.fans
            .map { "\($0.name): \(Int($0.rpm(forSpeed: preferences.cooling.fixedSpeed).rounded()).formatted()) rpm" }
            .joined(separator: " · ")
    }
}

// MARK: - Power profiles

/// Quiet on battery, more cooling when plugged in — without having to remember to switch.
private struct PowerProfilesCard: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences

        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Toggle(isOn: Binding(get: { preferences.powerProfiles.isEnabled },
                                     set: { model.setPowerProfilesEnabled($0) })) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text("Switch when plugging in or unplugging").font(.headline)
                        Text("You can still pick a mode by hand; it holds until the power source changes.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)

                if preferences.powerProfiles.isEnabled {
                    HStack(spacing: Theme.Spacing.xl) {
                        Picker(selection: $preferences.powerProfiles.onBattery) {
                            modes
                        } label: {
                            Label("On battery", systemImage: "battery.75percent")
                        }
                        Picker(selection: $preferences.powerProfiles.onAdapter) {
                            modes
                        } label: {
                            Label("Plugged in", systemImage: "powerplug")
                        }
                    }
                    .fixedSize()
                }
            }
        }
    }

    private var modes: some View {
        ForEach(CoolingMode.allCases, id: \.self) { mode in
            Text(mode.title).tag(mode)
        }
    }
}

private struct SafetyFootnote: View {
    var body: some View {
        Label {
            Text("MacFan gives the fans back to macOS when you quit, when your Mac sleeps, and whenever a part gets critically hot.")
        } icon: {
            Image(systemName: "checkmark.shield")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}
