import MatrixNetModel
import SwiftUI

/// The Usage tab's "Timeline" mode: one heat strip per app showing when it was
/// active over the selected window — hourly cells for Today, daily cells for
/// multi-day windows. Built from the persisted hourly usage (no packet capture).
struct ActivityTimelineView: View {
    let timeline: ActivityTimeline
    @Environment(AppModel.self) private var model

    private static let topApps = 30

    /// Best-effort app-name → icon from the live connection set; a historical app
    /// that is no longer running falls back to a generic mark.
    private var icons: [String: NSImage] {
        var result: [String: NSImage] = [:]
        for connection in model.connections {
            let name = connection.app.displayName
            if result[name] == nil, let icon = AppIconResolver.shared.cachedIcon(for: connection.app) {
                result[name] = icon
            }
        }
        return result
    }

    var body: some View {
        if timeline.rows.isEmpty {
            ContentUnavailableView(
                "No Activity Yet",
                systemImage: "chart.bar.xaxis",
                description: Text("Activity will appear here, by hour or day, as your apps use the network.")
            )
            .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            Panel {
                let icons = icons
                let maxBucket = timeline.rows.flatMap(\.buckets).max() ?? 1
                ForEach(timeline.rows.prefix(Self.topApps), id: \.app) { row in
                    rowView(row, icons: icons, maxBucket: maxBucket)
                }
            }
        }
    }

    private func rowView(_ row: AppActivityRow, icons: [String: NSImage], maxBucket: UInt64) -> some View {
        HStack(spacing: 8) {
            iconView(row.app, icons: icons)
            Text(row.app)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 130, alignment: .leading)
            HStack(spacing: 1) {
                ForEach(Array(row.buckets.enumerated()), id: \.offset) { index, bytes in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(cellColor(bytes, max: maxBucket))
                        .frame(height: 14)
                        .frame(maxWidth: .infinity)
                        .help(cellHelp(index: index, bytes: bytes))
                }
            }
            Text(Format.bytes(row.total))
                .font(Theme.mono(10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func iconView(_ app: String, icons: [String: NSImage]) -> some View {
        if let image = icons[app] {
            Image(nsImage: image).resizable().frame(width: 16, height: 16)
        } else {
            Image(systemName: "app.dashed").foregroundStyle(.secondary).frame(width: 16, height: 16)
        }
    }

    /// Log-scaled intensity so a few heavy buckets don't wash out lighter activity.
    private func cellColor(_ bytes: UInt64, max: UInt64) -> Color {
        guard bytes > 0, max > 0 else { return Color.primary.opacity(0.06) }
        let intensity = log(Double(bytes) + 1) / log(Double(max) + 1)
        return Theme.accent.opacity(0.15 + 0.85 * intensity)
    }

    private func cellHelp(index: Int, bytes: UInt64) -> String {
        guard index < timeline.hours.count else { return Format.bytes(bytes) }
        let date = timeline.hours[index]
        return "\(date.formatted(date: .abbreviated, time: .shortened)): \(Format.bytes(bytes))"
    }
}
