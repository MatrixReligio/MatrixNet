import MatrixNetModel
import SwiftUI

/// MatrixNet preferences window (Cmd-,), grouped into General, Updates and Data.
struct SettingsView: View {
    var updater: UpdateController

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            UpdatesSettings(updater: updater)
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
            DataSettings()
                .tabItem { Label("Data", systemImage: "cylinder.split.1x2") }
        }
        .frame(width: 480)
        .padding(20)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Preferences.Key.launchAtLogin.rawValue, store: SharedMetricsStore.sharedDefaults)
    private var launchAtLogin = false
    @AppStorage(Preferences.Key.runInBackground.rawValue, store: SharedMetricsStore.sharedDefaults)
    private var runInBackground = false
    @AppStorage(Preferences.Key.threatNotificationsEnabled.rawValue, store: SharedMetricsStore.sharedDefaults)
    private var threatNotifications = false
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in applyLaunchAtLogin(newValue) }
                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                }
            } footer: {
                Text("Start MatrixNet automatically when you log in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Run in background (menu bar only)", isOn: $runInBackground)
                    .onChange(of: runInBackground) { _, newValue in
                        NSApp.setActivationPolicy(newValue ? .accessory : .regular)
                    }
            } footer: {
                Text("Keep monitoring from the menu bar with no Dock icon, so the widget stays fresh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Notify about threat connections", isOn: $threatNotifications)
                    .onChange(of: threatNotifications) { _, newValue in
                        if newValue { model.threatNotifier?.requestAuthorizationIfNeeded() }
                    }
            } footer: {
                Text("Show a notification when an active connection reaches a flagged address.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        let controller = LoginItemController(manager: SMAppServiceLoginItem())
        do {
            try controller.setEnabled(enabled)
            loginError = nil
        } catch {
            loginError = String(localized: "Could not update the login item. Open Login Items in System Settings.")
        }
        // Reflect the service's real state (e.g. when approval is still required).
        if launchAtLogin != controller.isEnabled {
            launchAtLogin = controller.isEnabled
        }
    }
}

// MARK: - Updates

private struct UpdatesSettings: View {
    @ObservedObject var updater: UpdateController
    @State private var automatic: Bool

    init(updater: UpdateController) {
        self.updater = updater
        _automatic = State(initialValue: updater.automaticallyChecksForUpdates)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Automatically check for updates", isOn: $automatic)
                    .onChange(of: automatic) { _, newValue in
                        updater.automaticallyChecksForUpdates = newValue
                    }
                Button("Check for Updates Now…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            } footer: {
                Text("Updates are EdDSA-signed and verified before installation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Data

private struct DataSettings: View {
    @State private var checking = false
    @State private var geoIPChecked = GeoIP.lastChecked
    @State private var threatChecked = Threat.lastChecked

    var body: some View {
        Form {
            Section {
                LabeledContent("GeoIP database") { Text(checkedText(geoIPChecked)) }
                LabeledContent("Threat list") { Text(checkedText(threatChecked)) }
                Button("Check for Data Updates Now") { refresh() }
                    .disabled(checking)
            } footer: {
                Text("Datasets refresh automatically; MatrixNet only contacts its own release assets.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func checkedText(_ date: Date?) -> String {
        guard let date else { return String(localized: "Never checked") }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func refresh() {
        checking = true
        Task {
            await GeoIP.updateIfNeeded(force: true)
            await Threat.updateIfNeeded(force: true)
            geoIPChecked = GeoIP.lastChecked
            threatChecked = Threat.lastChecked
            checking = false
        }
    }
}
