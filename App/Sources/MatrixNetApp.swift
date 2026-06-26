import SwiftUI

@main
struct MatrixNetApp: App {
    @State private var model = AppModel()
    @State private var capture = PacketCaptureModel()

    var body: some Scene {
        Window("MatrixNet", id: "main") {
            RootView()
                .environment(model)
                .environment(capture)
                .frame(minWidth: 880, minHeight: 520)
                .onAppear { model.start() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra("MatrixNet", systemImage: "dot.radiowaves.left.and.right") {
            MenuBarView()
                .environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}
