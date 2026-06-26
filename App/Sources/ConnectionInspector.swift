import MatrixNetModel
import SwiftUI

/// Detail inspector for the selected connection: identity, endpoints, counters.
struct ConnectionInspector: View {
    let connection: Connection?

    var body: some View {
        if let connection {
            Form {
                Section("Application") {
                    LabeledContent("Name", value: connection.app.displayName)
                    LabeledContent("PID") { mono("\(connection.app.pid)") }
                    if let bundle = connection.app.bundleIdentifier {
                        LabeledContent("Bundle") { mono(bundle) }
                    }
                }
                Section("Flow") {
                    LabeledContent("Protocol", value: connection.fiveTuple.proto.displayName)
                    LabeledContent("Local") { mono(endpoint(connection.fiveTuple.source)) }
                    LabeledContent("Remote") { mono(endpoint(connection.fiveTuple.destination)) }
                    if let host = connection.remoteHostname {
                        LabeledContent("Host") { mono(host) }
                    }
                    LabeledContent("Scope", value: connection.fiveTuple.destination.address.scope.label)
                    if let country = GeoIP.country(for: connection.fiveTuple.destination.address) {
                        let flag = GeoIP.flag(for: connection.fiveTuple.destination.address) ?? ""
                        LabeledContent("Country", value: "\(flag) \(country)")
                    }
                }
                Section("Traffic") {
                    LabeledContent("Received") { mono(Format.bytes(connection.bytesIn)) }
                    LabeledContent("Sent") { mono(Format.bytes(connection.bytesOut)) }
                    LabeledContent("Packets") { mono("\(connection.packetsIn) / \(connection.packetsOut)") }
                    LabeledContent("State", value: connection.state == .active ? "Active" : "Closed")
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView(
                "No Selection",
                systemImage: "hand.point.up.left",
                description: Text("Select a connection to inspect its endpoints and traffic.")
            )
        }
    }

    private func endpoint(_ endpoint: Endpoint) -> String {
        "\(endpoint.address):\(endpoint.port)"
    }

    private func mono(_ text: String) -> some View {
        Text(text).font(Theme.mono(11)).textSelection(.enabled)
    }
}

/// Teaching empty state shown before any connections appear.
struct EmptyStateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Watching the Network", systemImage: "dot.radiowaves.left.and.right")
        } description: {
            Text(model.isMonitoring
                ? LocalizedStringKey("Listening for connections. Activity from every app will appear here.")
                :
                LocalizedStringKey(
                    "Start monitoring to see which apps are talking to the network — no special permissions required."
                ))
        } actions: {
            if !model.isMonitoring {
                Button("Start Monitoring") { model.start() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        }
    }
}

/// Shown when NetworkStatistics is unavailable (e.g. a future OS change).
struct UnavailableStateView: View {
    var body: some View {
        ContentUnavailableView(
            "Monitoring Unavailable",
            systemImage: "exclamationmark.triangle",
            description: Text("MatrixNet could not start passive monitoring on this system.")
        )
    }
}
