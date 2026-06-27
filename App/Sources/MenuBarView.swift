import MatrixNetModel
import SwiftUI

/// Compact menu-bar popover: live totals, the busiest apps, and a quick toggle.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var busiest: [Connection] {
        model.connections.sorted { $0.totalBytes > $1.totalBytes }.prefix(5).map(\.self)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("MatrixNet", systemImage: "dot.radiowaves.left.and.right")
                    .font(.headline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { model.isMonitoring },
                    set: { $0 ? model.start() : model.stop() }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Theme.accent)
            }

            HStack(spacing: 16) {
                metric("↓ Rate", Format.rate(model.throughputIn), Theme.inbound)
                metric("↑ Rate", Format.rate(model.throughputOut), Theme.outbound)
                metric("Active", "\(model.activeCount)", Theme.accent)
            }
            HStack(spacing: 16) {
                metric("Received", Format.bytes(model.sessionBytesIn), Theme.inbound)
                metric("Sent", Format.bytes(model.sessionBytesOut), Theme.outbound)
            }

            Divider()

            if busiest.isEmpty {
                Text("No active connections")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(busiest) { connection in
                    HStack {
                        Text(connection.app.displayName).lineLimit(1)
                        Spacer()
                        Text(Format.bytes(connection.totalBytes))
                            .font(Theme.mono(10)).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }

            Divider()

            HStack {
                Button("Open MatrixNet") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .font(.caption)
        }
        .padding(14)
        .frame(width: 280)
    }

    private func metric(_ label: LocalizedStringKey, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2.weight(.semibold)).textCase(.uppercase).foregroundStyle(color)
            // Fixed-width value keeps the columns from shifting as numbers change.
            Text(verbatim: value)
                .font(Theme.mono(12)).monospacedDigit()
                .lineLimit(1)
                .frame(width: 76, alignment: .leading)
        }
    }
}
