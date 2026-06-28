import SwiftUI

/// Top-level navigation: a calm sidebar of sections beside the detail content.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Section = .connections

    enum Section: String, CaseIterable, Identifiable {
        case overview
        case usage
        case connections
        case map
        case packets
        case history

        var id: String {
            rawValue
        }

        var title: LocalizedStringKey {
            switch self {
            case .overview: "Overview"
            case .usage: "Usage"
            case .connections: "Connections"
            case .map: "Map"
            case .packets: "Packets"
            case .history: "History"
            }
        }

        var symbol: String {
            switch self {
            case .overview: "chart.bar.xaxis.ascending"
            case .usage: "chart.bar.doc.horizontal"
            case .connections: "point.3.connected.trianglepath.dotted"
            case .map: "globe"
            case .packets: "scope"
            case .history: "clock.arrow.circlepath"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .safeAreaInset(edge: .bottom) { MonitorStatusBar() }
        } detail: {
            switch selection {
            case .overview: OverviewView()
            case .usage: UsageView()
            case .connections: ConnectionsView()
            case .map: GlobeView()
            case .packets: PacketsView()
            case .history: HistoryView()
            }
        }
    }
}

/// Footer in the sidebar showing whether passive monitoring is live.
private struct MonitorStatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isMonitoring ? Theme.accent : Color.secondary)
                .frame(width: 8, height: 8)
                .shadow(color: model.isMonitoring ? Theme.accent.opacity(0.6) : .clear, radius: 4)
            Text(model.isMonitoring ? LocalizedStringKey("Monitoring") : LocalizedStringKey("Paused"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(model.activeCount) active")
                .font(Theme.mono(11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
