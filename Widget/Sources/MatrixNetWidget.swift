import MatrixNetModel
import SwiftUI
import WidgetKit

private let phosphor = Color(red: 0.18, green: 0.62, blue: 0.42)

struct MetricsEntry: TimelineEntry {
    let date: Date
    let snapshot: MetricsSnapshot
}

struct MetricsProvider: TimelineProvider {
    func placeholder(in _: Context) -> MetricsEntry {
        MetricsEntry(date: Date(), snapshot: .empty)
    }

    func getSnapshot(in _: Context, completion: @escaping (MetricsEntry) -> Void) {
        completion(MetricsEntry(date: Date(), snapshot: load()))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<MetricsEntry>) -> Void) {
        let entry = MetricsEntry(date: Date(), snapshot: load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60))))
    }

    private func load() -> MetricsSnapshot {
        SharedMetricsStore.defaultURL().flatMap(SharedMetricsStore.read) ?? .empty
    }
}

private func formatBytes(_ value: UInt64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var scaled = Double(value)
    var unit = 0
    while scaled >= 1024, unit < units.count - 1 {
        scaled /= 1024
        unit += 1
    }
    return unit == 0 ? "\(value) B" : String(format: "%.1f %@", scaled, units[unit])
}

struct MatrixNetWidgetView: View {
    var entry: MetricsEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(phosphor)
                Text("MatrixNet").font(.caption.weight(.semibold))
                Spacer()
                Text("\(entry.snapshot.activeConnections)")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(phosphor)
                    .monospacedDigit()
            }
            Text("active connections").font(.caption2).foregroundStyle(.secondary)

            HStack(spacing: 14) {
                metric("IN", formatBytes(entry.snapshot.bytesIn))
                metric("OUT", formatBytes(entry.snapshot.bytesOut))
            }

            if family != .systemSmall, !entry.snapshot.topApps.isEmpty {
                Divider()
                ForEach(entry.snapshot.topApps.prefix(3), id: \.name) { app in
                    HStack {
                        Text(app.name).font(.caption2).lineLimit(1)
                        Spacer()
                        Text(formatBytes(app.bytes))
                            .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9).weight(.semibold)).foregroundStyle(phosphor)
            Text(value).font(.caption2).monospacedDigit()
        }
    }
}

struct MatrixNetWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MatrixNetWidget", provider: MetricsProvider()) { entry in
            MatrixNetWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("MatrixNet")
        .description("Live network activity, by app.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct MatrixNetWidgetBundle: WidgetBundle {
    var body: some Widget {
        MatrixNetWidget()
    }
}
