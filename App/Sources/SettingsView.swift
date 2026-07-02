import MatrixNetGeoIP
import MatrixNetModel
import ServiceManagement
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
    @AppStorage(Preferences.Key.newDestinationAlertsEnabled.rawValue, store: SharedMetricsStore.sharedDefaults)
    private var newDestinationAlerts = false
    @AppStorage(Preferences.Key.proxyGeoResolutionEnabled.rawValue, store: SharedMetricsStore.sharedDefaults)
    private var proxyGeoResolution = true
    @AppStorage(Preferences.Key.homeRegion.rawValue, store: SharedMetricsStore.sharedDefaults)
    private var homeRegion = ""
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in applyLaunchAtLogin(newValue) }
                Button("Manage in System Settings…") {
                    SMAppService.openSystemSettingsLoginItems()
                }
                .controlSize(.small)
                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                }
            } footer: {
                Text("Start MatrixNet at login — added silently; verify under Login Items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Run in background (menu bar only)", isOn: $runInBackground)
                    .onChange(of: runInBackground) { _, _ in
                        // Window-aware: the Dock icon only hides once no window is
                        // open, so the app never becomes unreachable.
                        (NSApp.delegate as? AppDelegate)?.syncActivationPolicy()
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

            Section {
                Toggle("Notify about new destinations", isOn: $newDestinationAlerts)
                    .onChange(of: newDestinationAlerts) { _, newValue in
                        if newValue { model.newDestinationNotifier?.requestAuthorizationIfNeeded() }
                    }
            } footer: {
                Text("Alert when a known app first reaches a country it has never reached before.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Resolve country for proxied destinations", isOn: $proxyGeoResolution)
            } footer: {
                Text(
                    """
                    Recovers a proxied destination's country by resolving its domain via \
                    encrypted DNS (DoH). On by default. When on, this sends the observed \
                    domain of a proxied flow to Cloudflare (1.1.1.1) — the only case where \
                    MatrixNet contacts a third party. Turn it off to stay fully on-device.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Picker("Home region (Map)", selection: $homeRegion) {
                    Text("Automatic (system region)").tag("")
                    ForEach(WorldMapStore.selectableRegions, id: \.self) { code in
                        Text(verbatim: regionLabel(code)).tag(code)
                    }
                }
            } footer: {
                Text("Where the Map’s “this Mac” anchor sits. Defaults to your system region.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func regionLabel(_ code: String) -> String {
        let name = Locale.current.localizedString(forRegionCode: code) ?? code
        if let flag = GeoIPDatabase.flag(for: code) {
            return "\(flag) \(name)"
        }
        return name
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
    @AppStorage(Preferences.Key.usageRetentionDays.rawValue, store: SharedMetricsStore.sharedDefaults)
    private var usageRetentionDays = 90
    @AppStorage(Preferences.Key.historyRetentionDays.rawValue, store: SharedMetricsStore.sharedDefaults)
    private var historyRetentionDays = 30
    @AppStorage(Preferences.Key.billingCycleResetDay.rawValue, store: SharedMetricsStore.sharedDefaults)
    private var billingCycleResetDay = 1

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

            Section {
                Stepper(value: $usageRetentionDays, in: 7 ... 365) {
                    Text("Keep usage history for \(usageRetentionDays) days")
                }
                Stepper(value: $historyRetentionDays, in: 7 ... 365) {
                    Text("Keep connection history for \(historyRetentionDays) days")
                }
                Stepper(value: $billingCycleResetDay, in: 1 ... 28) {
                    Text("Billing cycle resets on day \(billingCycleResetDay)")
                }
            } footer: {
                Text("Controls the Usage and History tabs’ retention and the billing-cycle reporting window.")
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
