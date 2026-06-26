import MatrixNetModel
import SwiftUI

/// A calm dashboard: live totals and the apps generating the most traffic.
struct OverviewView: View {
    @Environment(AppModel.self) private var model

    private var topApps: [(app: AppIdentity, bytes: UInt64)] {
        Dictionary(grouping: model.connections, by: \.app.pid)
            .compactMap { _, group -> (AppIdentity, UInt64)? in
                guard let app = group.first?.app else { return nil }
                return (app, group.reduce(0) { $0 &+ $1.totalBytes })
            }
            .sorted { $0.1 > $1.1 }
            .prefix(8)
            .map { (app: $0.0, bytes: $0.1) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 16) {
                    StatTile(label: "Active", value: "\(model.activeCount)", tint: Theme.accent)
                    StatTile(label: "Received", value: Format.bytes(model.totalBytesIn), tint: Theme.inbound)
                    StatTile(label: "Sent", value: Format.bytes(model.totalBytesOut), tint: Theme.outbound)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Top Talkers")
                        .font(.headline)
                    if topApps.isEmpty {
                        Text("No traffic yet.")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(topApps, id: \.app.pid) { entry in
                            TopTalkerRow(app: entry.app, bytes: entry.bytes, maxBytes: topApps.first?.bytes ?? 1)
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Overview")
        .background(.background)
    }
}

private struct StatTile: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(Theme.mono(22, weight: .medium))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct TopTalkerRow: View {
    let app: AppIdentity
    let bytes: UInt64
    let maxBytes: UInt64

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = AppIconResolver.shared.icon(for: app) {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "terminal").foregroundStyle(.secondary)
                }
            }
            .frame(width: 20, height: 20)

            Text(app.displayName).lineLimit(1).frame(width: 160, alignment: .leading)

            GeometryReader { geometry in
                Capsule()
                    .fill(Theme.accent.opacity(0.18))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Theme.accent)
                            .frame(width: geometry.size.width * fraction)
                    }
            }
            .frame(height: 6)

            Text(Format.bytes(bytes))
                .font(Theme.mono(11)).monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
        }
    }

    private var fraction: Double {
        guard maxBytes > 0 else { return 0 }
        return max(0.02, Double(bytes) / Double(maxBytes))
    }
}
