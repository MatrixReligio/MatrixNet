import MatrixNetModel
import SwiftUI

/// The primary view: every app's live network connections, attributed by the
/// kernel, in a precise sortable table with a detail inspector.
struct ConnectionsView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var selection: Connection.ID?
    @State private var sortOrder = [KeyPathComparator(\Connection.lastActivityAt, order: .reverse)]
    @State private var columns = TableColumnCustomization<Connection>()
    @State private var showInspector = true
    @AppStorage(Preferences.Key.showDomains.rawValue, store: SharedMetricsStore.sharedDefaults)
    private var showDomains = true

    private var filtered: [Connection] {
        let base = search.isEmpty ? model.connections : model.connections.filter { matches($0, search) }
        return base.sorted(using: sortOrder)
    }

    private var selectedConnection: Connection? {
        model.connections.first { $0.id == selection }
    }

    var body: some View {
        Group {
            if model.monitoringUnavailable {
                UnavailableStateView()
            } else if model.connections.isEmpty {
                EmptyStateView()
            } else {
                table
            }
        }
        .navigationTitle("Connections")
        .searchable(text: $search, placement: .toolbar, prompt: "Filter by app, host, or IP")
        .toolbar { toolbarContent }
        .inspector(isPresented: $showInspector) {
            ConnectionInspector(connection: selectedConnection)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 360)
        }
    }

    private var table: some View {
        Table(filtered, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
            TableColumn("Application", value: \.app.displayName) { connection in
                AppCell(app: connection.app)
            }
            .width(min: 160, ideal: 220)
            .customizationID("application")

            TableColumn("Proto", value: \.fiveTuple.proto.displayName) { connection in
                Text(connection.fiveTuple.proto.displayName)
                    .font(Theme.mono(11))
                    .foregroundStyle(.secondary)
            }
            .width(min: 44, ideal: 52, max: 90)
            .customizationID("proto")

            TableColumn("Role", value: \.fiveTuple.role.rawValue) { connection in
                RoleBadge(role: connection.fiveTuple.role)
            }
            .width(min: 56, ideal: 72, max: 110)
            .customizationID("role")

            TableColumn("Remote", value: \.fiveTuple.destination.address.description) { connection in
                HStack(spacing: 5) {
                    if Threat.isThreat(connection.fiveTuple.destination.address) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.danger)
                            .help("On a public threat-intelligence blocklist (IPsum).")
                    }
                    if let flag = GeoIP.flag(for: connection.fiveTuple.destination.address) {
                        Text(flag)
                    }
                    Text(remoteLabel(connection))
                        .font(Theme.mono(11))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if ProxyInfo.routesThroughProxy(connection.fiveTuple.destination) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption2)
                            .foregroundStyle(Theme.advisory)
                            .help("Routed through your local/configured proxy.")
                    }
                }
                .help(remoteLabel(connection))
            }
            .width(min: 160, ideal: 220)
            .customizationID("remote")

            TableColumn("In", value: \.bytesIn) { connection in
                Text(Format.bytes(connection.bytesIn))
                    .font(Theme.mono(11)).monospacedDigit()
                    .foregroundStyle(Theme.inbound)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 56, ideal: 76, max: 140)
            .customizationID("in")

            TableColumn("Out", value: \.bytesOut) { connection in
                Text(Format.bytes(connection.bytesOut))
                    .font(Theme.mono(11)).monospacedDigit()
                    .foregroundStyle(Theme.outbound)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 56, ideal: 76, max: 140)
            .customizationID("out")

            TableColumn("State", value: \.state) { connection in
                StateBadge(state: connection.state)
            }
            .width(min: 60, ideal: 76, max: 120)
            .customizationID("state")
        }
        .tableStyle(.inset)
        .persistTableColumns($columns, key: "table.connections")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            ThroughputSummary()
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.isMonitoring ? model.stop() : model.start()
            } label: {
                Label(
                    model.isMonitoring ? LocalizedStringKey("Pause") : LocalizedStringKey("Monitor"),
                    systemImage: model.isMonitoring ? "pause.fill" : "play.fill"
                )
            }
            .tint(Theme.accent)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showDomains.toggle() } label: {
                Label(
                    showDomains ? LocalizedStringKey("Domains") : LocalizedStringKey("IPs"),
                    systemImage: showDomains ? "globe" : "number"
                )
            }
            .help("Show domain names or IP addresses")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showInspector.toggle() } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
        }
    }

    private func remoteLabel(_ connection: Connection) -> String {
        let endpoint = connection.fiveTuple.destination
        let host = AddressDisplay.host(
            ip: endpoint.address.description,
            name: connection.remoteHostname,
            showDomains: showDomains
        )
        return "\(host):\(endpoint.port)"
    }

    private func matches(_ connection: Connection, _ query: String) -> Bool {
        let needle = query.lowercased()
        if connection.app.displayName.lowercased().contains(needle) { return true }
        if remoteLabel(connection).lowercased().contains(needle) { return true }
        return false
    }
}

/// App icon + name + PID cell.
private struct AppCell: View {
    let app: AppIdentity

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let icon = AppIconResolver.shared.cachedIcon(for: app) {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "terminal").foregroundStyle(.secondary)
                }
            }
            .frame(width: 18, height: 18)

            Text(app.displayName).lineLimit(1).truncationMode(.tail)
            if ProxyInfo.isTunnel(app.displayName) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.caption2)
                    .foregroundStyle(Theme.accent)
                    .help("VPN/proxy tunnel — relays other apps' traffic.")
            }
            Spacer(minLength: 4)
            Text(verbatim: "\(app.pid)")
                .font(Theme.mono(10)).monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(app.displayName)
    }
}

/// Shows whether the local host is the client or server side of a connection,
/// inferred heuristically from the ports.
private struct RoleBadge: View {
    let role: ConnectionRole

    var body: some View {
        switch role {
        case .client:
            label("Client", systemImage: "arrow.up.forward", color: Theme.outbound)
        case .server:
            label("Server", systemImage: "arrow.down.backward", color: Theme.inbound)
        case .unknown:
            Text(verbatim: "—").foregroundStyle(.tertiary)
        }
    }

    private func label(_ title: LocalizedStringKey, systemImage: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).font(.caption2)
            Text(title).font(.caption2.weight(.medium))
        }
        .foregroundStyle(color)
    }
}

private struct StateBadge: View {
    let state: ConnectionState

    var body: some View {
        Text(state == .active ? LocalizedStringKey("Active") : LocalizedStringKey("Closed"))
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                (state == .active ? Theme.accent : Theme.advisory).opacity(0.16),
                in: Capsule()
            )
            .foregroundStyle(state == .active ? Theme.accent : Theme.advisory)
    }
}

/// Live aggregate throughput shown in the toolbar's principal slot.
private struct ThroughputSummary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            metric("IN", Format.rate(model.throughputIn), Theme.inbound)
            metric("OUT", Format.rate(model.throughputOut), Theme.outbound)
        }
        // Inset from the toolbar capsule's rounded edges so the first label
        // doesn't hug the left border.
        .padding(.horizontal, 10)
    }

    private func metric(_ label: LocalizedStringKey, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(color)
            // Fixed-width value so the toolbar readout doesn't jump as the rate's
            // digit count and unit change.
            Text(verbatim: value)
                .font(Theme.mono(11)).monospacedDigit().foregroundStyle(.primary)
                .lineLimit(1)
                .frame(width: 74, alignment: .leading)
        }
    }
}
