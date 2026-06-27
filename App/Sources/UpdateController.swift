import Sparkle
import SwiftUI

/// Bridges Sparkle's updater into SwiftUI. The updater reads its feed URL and
/// EdDSA public key from the app's Info.plist (`SUFeedURL`, `SUPublicEDKey`) and
/// checks the GitHub "latest release" appcast. Every downloaded update is
/// verified against the embedded public key and the Developer ID signature, so
/// an update can never be substituted in transit.
@MainActor
final class UpdateController: ObservableObject {
    private let controller: SPUStandardUpdaterController

    /// Whether the updater is currently able to check (drives menu enablement).
    @Published var canCheckForUpdates = false

    init() {
        // startingUpdater: true begins the scheduled background checks honoring
        // the user's preference (SUEnableAutomaticChecks defaults it on).
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// Presents Sparkle's standard "check for updates" flow.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    /// Whether Sparkle checks for updates automatically in the background.
    /// Sparkle persists this itself (the `SUEnableAutomaticChecks` default), so
    /// it is the single source of truth for the Settings toggle.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
}

/// A "Check for Updates…" menu command wired to the shared updater.
struct CheckForUpdatesCommand: View {
    @ObservedObject var updater: UpdateController

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
    }
}
