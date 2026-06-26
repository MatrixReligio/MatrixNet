import MatrixNetModel
import SwiftUI

/// The primary view: every app's live network connections, attributed by the
/// kernel, in a precise sortable table with a detail inspector.
struct ConnectionsView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var selection: Connection.ID?
    @State private var sortOrder = [KeyPathComparator(\Connection.lastActivityAt, order: .reverse)]
    @State private var showInspector = true

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
        Table(filtered, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Application") { connection in
                AppCell(app: connection.app)
            }
            .width(min: 180, ideal: 220)

            TableColumn("Proto", value: \.fiveTuple.proto.displayName) { connection in
                Text(connection.fiveTuple.proto.displayName)
                    .font(Theme.mono(11))
                    .foregroundStyle(.secondary)
            }
            .width(52)

            TableColumn("Remote") { connection in
                HStack(spacing: 5) {
                    if let flag = GeoIP.flag(for: connection.fiveTuple.destination.address) {
                        Text(flag)
                    }
                    Text(remoteLabel(connection))
                        .font(Theme.mono(11))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .width(min: 160, ideal: 220)

            TableColumn("In", value: \.bytesIn) { connection in
                Text(Format.bytes(connection.bytesIn))
                    .font(Theme.mono(11)).monospacedDigit()
                    .foregroundStyle(Theme.inbound)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(72)

            TableColumn("Out", value: \.bytesOut) { connection in
                Text(Format.bytes(connection.bytesOut))
                    .font(Theme.mono(11)).monospacedDigit()
                    .foregroundStyle(Theme.outbound)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(72)

            TableColumn("State") { connection in
                StateBadge(state: connection.state)
            }
            .width(72)
        }
        .tableStyle(.inset)
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
                    model.isMonitoring ? "Pause" : "Monitor",
                    systemImage: model.isMonitoring ? "pause.fill" : "play.fill"
                )
            }
            .tint(Theme.accent)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showInspector.toggle() } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
        }
    }

    private func remoteLabel(_ connection: Connection) -> String {
        let endpoint = connection.fiveTuple.destination
        let host = connection.remoteHostname ?? endpoint.address.description
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

            Text(app.displayName).lineLimit(1)
            Spacer(minLength: 4)
            Text("\(app.pid)")
                .font(Theme.mono(10)).monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }
}

private struct StateBadge: View {
    let state: ConnectionState

    var body: some View {
        Text(state == .active ? "Active" : "Closed")
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
            metric("IN", Format.bytes(model.totalBytesIn), Theme.inbound)
            metric("OUT", Format.bytes(model.totalBytesOut), Theme.outbound)
        }
    }

    private func metric(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(color)
            Text(value).font(Theme.mono(11)).monospacedDigit().foregroundStyle(.primary)
        }
    }
}
