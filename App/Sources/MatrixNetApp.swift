import SwiftUI

private enum Links {
    static let repository = URL(string: "https://github.com/MatrixReligio/MatrixNet")!
    static let issues = URL(string: "https://github.com/MatrixReligio/MatrixNet/issues")!
}

@main
struct MatrixNetApp: App {
    @State private var model = AppModel()
    @State private var capture = PacketCaptureModel()
    @StateObject private var updater = UpdateController()

    var body: some Scene {
        Window("MatrixNet", id: "main") {
            RootView()
                .environment(model)
                .environment(capture)
                .frame(minWidth: 880, minHeight: 520)
                .onAppear {
                    capture.attribution = model.aggregator
                    model.start()
                    ProxyInfo.refresh()
                    Task.detached(priority: .background) { await GeoIP.updateIfNeeded() }
                    Task.detached(priority: .background) { await Threat.updateIfNeeded() }
                }
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

        MenuBarExtra("MatrixNet", systemImage: "dot.radiowaves.left.and.right") {
            MenuBarView()
                .environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}
