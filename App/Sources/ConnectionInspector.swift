import MatrixNetModel
import MatrixNetStore
import SwiftUI

/// Detail inspector for the selected connection: identity, endpoints, counters.
struct ConnectionInspector: View {
    let connection: Connection?
    @Environment(AppModel.self) private var model
    @Environment(PacketCaptureModel.self) private var capture

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
                    LabeledContent("Scope") {
                        Text(LocalizedStringKey(connection.fiveTuple.destination.address.scope.label))
                    }
                    roleContent(connection.fiveTuple.role)
                    if ProxyInfo.routesThroughProxy(connection.fiveTuple.destination) {
                        LabeledContent("Routing") { Text("Through proxy or tunnel") }
                    } else if ProxyInfo.isTunnel(connection.app.displayName) {
                        LabeledContent("Routing") { Text("VPN/proxy tunnel") }
                    }
                    if let country = GeoIP.country(for: connection.fiveTuple.destination.address) {
                        let flag = GeoIP.flag(for: connection.fiveTuple.destination.address) ?? ""
                        LabeledContent("Country", value: "\(flag) \(country)")
                    }
                    if Threat.isThreat(connection.fiveTuple.destination.address) {
                        LabeledContent("Threat") {
                            Label("On threat blocklist", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.danger)
                                .font(.callout.weight(.medium))
                        }
                    }
                }
                Section("Traffic") {
                    LabeledContent("Received") { mono(Format.bytes(connection.bytesIn)) }
                    LabeledContent("Sent") { mono(Format.bytes(connection.bytesOut)) }
                    LabeledContent("Packets") { mono("\(connection.packetsIn) / \(connection.packetsOut)") }
                    LabeledContent("State") {
                        Text(connection.state == .active ? LocalizedStringKey("Active") : LocalizedStringKey("Closed"))
                    }
                }
                fingerprintSection(for: connection)
                qualitySection(for: connection)
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

    /// The app's observed JA4 TLS client fingerprints — which TLS stacks the
    /// process has been seen using. Requires packet capture (a ClientHello);
    /// shows guidance otherwise.
    @ViewBuilder
    private func fingerprintSection(for connection: Connection) -> some View {
        let fingerprints = model.fingerprints(for: connection.app.displayName)
        Section("TLS Fingerprint") {
            if fingerprints.isEmpty {
                Text(capture.isCapturing
                    ? LocalizedStringKey("No TLS fingerprint observed yet for this app.")
                    : LocalizedStringKey("Enable packet capture in the Packets tab to see TLS fingerprints."))
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(fingerprints, id: \.ja4) { fingerprint in
                    LabeledContent {
                        mono(fingerprint.ja4)
                    } label: {
                        if let label = fingerprint.label {
                            Text(verbatim: label)
                        } else {
                            Text("Unknown stack")
                        }
                    }
                }
            }
        }
    }

    /// Passively measured network quality for this connection's flow — handshake
    /// RTT, retransmits, and setup time. Requires packet capture (per-packet
    /// timing); shows guidance otherwise. TCP only.
    private func qualitySection(for connection: Connection) -> some View {
        Section("Network Quality") {
            if connection.fiveTuple.proto != .tcp {
                Text("Network quality is measured for TCP connections.")
                    .foregroundStyle(.secondary).font(.callout)
            } else if let quality = model.quality(for: connection) {
                if let rtt = quality.handshakeRTTms {
                    LabeledContent("Handshake RTT") { mono(String(format: "%.1f ms", rtt)) }
                }
                if let setup = quality.setupMs {
                    LabeledContent("Connection Setup") { mono(String(format: "%.1f ms", setup)) }
                }
                LabeledContent("Retransmits") { mono("\(quality.retransmits)") }
                LabeledContent("Out of Order") { mono("\(quality.outOfOrder)") }
                if quality.handshakeRTTms == nil {
                    Text("Handshake not captured (connection opened before capture).")
                        .foregroundStyle(.secondary).font(.caption)
                }
            } else {
                Text(capture.isCapturing
                    ? LocalizedStringKey("No quality data observed yet for this connection.")
                    : LocalizedStringKey("Enable packet capture in the Packets tab to measure network quality."))
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
    }

    @ViewBuilder
    private func roleContent(_ role: ConnectionRole) -> some View {
        switch role {
        case .client: LabeledContent("Role") { Text("Client") }
        case .server: LabeledContent("Role") { Text("Server") }
        case .unknown: EmptyView()
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
