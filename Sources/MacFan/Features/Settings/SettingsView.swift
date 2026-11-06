import AppKit
import MacFanCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AlertSettings()
                .tabItem { Label("Alerts", systemImage: "bell") }
            LoggingSettings()
                .tabItem { Label("Logging", systemImage: "doc.text") }
            HelperSettings()
                .tabItem { Label("Helper", systemImage: "lock.shield") }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var preferences
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Toggle("Show in Dock", isOn: $preferences.showsDockIcon)
                    .onChange(of: preferences.showsDockIcon) { model.applyDockIconPreference() }
            }

            Section {
                Picker("Temperature", selection: $preferences.unit) {
                    Text("Celsius").tag(TemperatureUnit.celsius)
                    Text("Fahrenheit").tag(TemperatureUnit.fahrenheit)
                }
                Picker("Menu bar shows", selection: $preferences.menuBarDisplay) {
                    Text("Temperature").tag(MenuBarDisplay.temperature)
                    Text("Fan speed").tag(MenuBarDisplay.fanSpeed)
                    Text("Both").tag(MenuBarDisplay.both)
                    Text("Icon only").tag(MenuBarDisplay.iconOnly)
                }
                LabeledContent("Menu bar sensor") {
                    HStack {
                        Text(menuBarSensorName).foregroundStyle(.secondary)
                        if preferences.menuBarSensorID != nil {
                            Button("Reset") { preferences.menuBarSensorID = nil }
                        }
                    }
                }
            } footer: {
                Text("To show a different sensor, right-click it in Sensors.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if model.updates.isAvailable {
                UpdateSettings(updates: model.updates)
            }

            Section {
                Picker("Update every", selection: $preferences.refreshInterval) {
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                }
                Button("Search for Sensors Again") { model.rediscoverSensors() }
            }

            Section {
                Toggle("Keep my fan setting during emergencies", isOn: $preferences.cooling.keepsSettingInEmergency)
            } footer: {
                Label("Risky. An emergency is when a part reaches its critical temperature or macOS reports critical thermal pressure. Normally Smart Curve and Fixed Speed then run every fan at full speed until both have eased. With this on, they keep following your setting with their usual minimum speeds, so parts can stay hot for longer. Full Speed and Automatic aren't affected.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
    }

    private var menuBarSensorName: String {
        guard let id = preferences.menuBarSensorID else { return String(localized: "Hottest CPU") }
        return model.snapshot.reading(id: id)?.sensor.name ?? id
    }
}

private struct UpdateSettings: View {
    @Bindable var updates: UpdateManager

    var body: some View {
        Section {
            Toggle("Check for updates automatically", isOn: $updates.automaticallyChecksForUpdates)
            LabeledContent("Version \(updates.currentVersion)") {
                Button("Check Now") { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates)
            }
        } footer: {
            Text("Updates come from MacFan's GitHub releases and are verified with a signature before installing.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct AlertSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section {
                Toggle("Notify me when my Mac runs hot", isOn: Binding(
                    get: { preferences.alertsEnabled },
                    set: { enabled in Task { await model.enableAlerts(enabled) } }
                ))
            } footer: {
                Text("Alerts fire only after a temperature stays high for 30 seconds, and at most every 15 minutes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("CPU and GPU") {
                LabeledContent("Alert above") {
                    Stepper(value: $preferences.alertThreshold, in: 70...105, step: 1) {
                        Text(preferences.unit.format(preferences.alertThreshold, showsUnit: true)).monospacedDigit()
                    }
                }
            }
            .disabled(!preferences.alertsEnabled)

            Section("Battery") {
                LabeledContent("Alert above", value: preferences.unit.format(SensorCategory.battery.thresholds.hot, showsUnit: true))
            }
            .disabled(!preferences.alertsEnabled)
        }
        .formStyle(.grouped)
    }
}

private struct LoggingSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section {
                Toggle("Record temperatures and fan speeds", isOn: $preferences.loggingEnabled)
                Picker("Every", selection: $preferences.loggingInterval) {
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                    Text("1 minute").tag(60.0)
                }
                .disabled(!preferences.loggingEnabled)
            } footer: {
                Text("One CSV file per day, ready for Numbers or Excel. Logs stay on this Mac.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Show Logs in Finder") {
                    try? FileManager.default.createDirectory(at: model.logDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(model.logDirectory)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct HelperSettings: View {
    @Environment(AppModel.self) private var model
    @State private var isWorking = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    Label(statusText, systemImage: model.helper.isReady ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(model.helper.isReady ? .green : .secondary)
                }
            } footer: {
                Text("The helper is only needed to change fan speeds. It runs as root, accepts commands only from MacFan, and returns the fans to macOS if MacFan quits or stops responding.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    if model.helper.isReady {
                        Button("Uninstall Helper", role: .destructive) { run { await model.helper.uninstall() } }
                    } else if model.helper.status == .requiresApproval {
                        Button("Open Login Items…") { model.helper.openLoginItemsSettings() }
                    } else {
                        Button("Install Helper") { run { await model.helper.install() } }
                    }
                    if isWorking { ProgressView().controlSize(.small) }
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.helper.refresh() }
    }

    private var statusText: LocalizedStringKey {
        switch model.helper.status {
        case .unknown: "Checking…"
        case .notInstalled: "Not installed"
        case .requiresApproval: "Waiting for approval"
        case .ready: "Installed and running"
        case .outdated: "Needs update"
        case .unavailable: "Not responding"
        }
    }

    private func run(_ work: @escaping () async -> Void) {
        isWorking = true
        Task {
            await work()
            isWorking = false
        }
    }
}
