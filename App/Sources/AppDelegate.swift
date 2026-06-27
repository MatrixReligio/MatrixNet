import AppKit
import MatrixNetModel
import SwiftUI

/// Owns the long-lived monitoring engine so it runs for the whole process
/// lifetime — independent of whether the main window is open. This keeps the
/// shared App Group snapshot (and therefore the desktop widget) fresh even when
/// the window is closed or the app runs as a menu-bar-only agent.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let capture = PacketCaptureModel()
    let notifier = ThreatNotifier()

    private var preferences: Preferences {
        Preferences(defaults: SharedMetricsStore.sharedDefaults ?? .standard)
    }

    func applicationDidFinishLaunching(_: Notification) {
        // Apply the saved background (menu-bar-only) mode before the UI settles.
        NSApp.setActivationPolicy(preferences.runInBackground ? .accessory : .regular)

        capture.attribution = model.aggregator
        model.threatNotifier = notifier
        model.start()
        ProxyInfo.refresh()
        Task.detached(priority: .background) { await GeoIP.updateIfNeeded() }
        Task.detached(priority: .background) { await Threat.updateIfNeeded() }
    }

    /// Keep monitoring (and the widget's data source) alive after the last window
    /// closes; the app continues as a menu-bar agent until the user quits.
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }
}
