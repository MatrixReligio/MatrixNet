import SwiftUI

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
                    model.start()
                    Task.detached(priority: .background) { await GeoIP.updateIfNeeded() }
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            // Place "Check for Updates…" in the application menu, next to About.
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand(updater: updater)
            }
        }

        MenuBarExtra("MatrixNet", systemImage: "dot.radiowaves.left.and.right") {
            MenuBarView()
                .environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}
