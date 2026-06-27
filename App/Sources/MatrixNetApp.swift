import MatrixNetModel
import SwiftUI

private enum Links {
    static let repository = URL(string: "https://github.com/MatrixReligio/MatrixNet")!
    static let issues = URL(string: "https://github.com/MatrixReligio/MatrixNet/issues")!
}

@main
struct MatrixNetApp: App {
    // The delegate owns the monitoring engine so it runs for the whole process
    // lifetime, independent of the window — keeping the widget fresh.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var updater = UpdateController()

    var body: some Scene {
        Window("MatrixNet", id: "main") {
            RootView()
                .environment(appDelegate.model)
                .environment(appDelegate.capture)
                .frame(minWidth: 880, minHeight: 520)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            // Place "Check for Updates…" in the application menu, next to About.
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand(updater: updater)
            }
            // The default Help menu points at a non-existent help book ("No help
            // found"); replace it with links to the project's open-source pages.
            CommandGroup(replacing: .help) {
                Link("MatrixNet on GitHub", destination: Links.repository)
                Link("Report an Issue", destination: Links.issues)
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environment(appDelegate.model)
        } label: {
            MenuBarTitle(model: appDelegate.model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(updater: updater)
                .environment(appDelegate.model)
        }
    }
}

/// The menu-bar status item label: the brand icon plus live down/up throughput.
/// The icon keeps the item recognizable in a crowded menu bar (and findable when
/// the app runs Dock-less); reading the model's rates makes the text update live.
private struct MenuBarTitle: View {
    let model: AppModel

    var body: some View {
        Label {
            Text(MenuBarRateFormatter.compact(in: model.throughputIn, out: model.throughputOut))
        } icon: {
            Image(systemName: "dot.radiowaves.left.and.right")
        }
    }
}
