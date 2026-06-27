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
        // Always start as a normal app (Dock icon + app menu) so the window,
        // menu, and Settings stay reachable. Background (menu-bar-only) mode
        // engages only once the last window closes — see syncActivationPolicy().
        NSApp.setActivationPolicy(.regular)

        capture.attribution = model.aggregator
        model.threatNotifier = notifier
        model.start()
        ProxyInfo.refresh()
        Task.detached(priority: .background) { await GeoIP.updateIfNeeded() }
        Task.detached(priority: .background) { await Threat.updateIfNeeded() }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    /// Keep monitoring (and the widget's data source) alive after the last window
    /// closes; the app continues as a menu-bar agent until the user quits.
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    /// Re-show and refront the main window when the Dock icon is clicked.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    @objc private func windowWillClose() {
        // willClose fires before the window leaves NSApp.windows; re-check next tick.
        perform(#selector(syncActivationPolicy), with: nil, afterDelay: 0.1)
    }

    /// Show the Dock icon + app menu whenever a window is open; hide them
    /// (menu-bar-only) only when no window remains and the user opted into
    /// background mode. This prevents the app from becoming unreachable.
    @objc func syncActivationPolicy() {
        let hasWindow = NSApp.windows.contains { window in
            window.isVisible && window.styleMask.contains(.titled)
        }
        let policy: NSApplication.ActivationPolicy =
            (preferences.runInBackground && !hasWindow) ? .accessory : .regular
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }

    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        for window in NSApp.windows where window.styleMask.contains(.titled) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
