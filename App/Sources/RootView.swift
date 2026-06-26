import SwiftUI

/// Top-level navigation: a calm sidebar of sections beside the detail content.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Section = .connections

    enum Section: String, CaseIterable, Identifiable {
        case overview
        case connections

        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .overview: "Overview"
            case .connections: "Connections"
            }
        }

        var symbol: String {
            switch self {
            case .overview: "chart.bar.xaxis.ascending"
            case .connections: "point.3.connected.trianglepath.dotted"
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
            case .connections: ConnectionsView()
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
            Text(model.isMonitoring ? "Monitoring" : "Paused")
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
