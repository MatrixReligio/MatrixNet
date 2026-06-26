import MatrixNetModel
import SwiftUI
import WidgetKit

// MARK: - Palette (mirrors the app's phosphor instrument theme; the widget is a
// separate target and cannot import the app's design system).

private enum Palette {
    static let accent = Color(light: Color(red: 0.06, green: 0.46, blue: 0.34),
                              dark: Color(red: 0.32, green: 0.82, blue: 0.58))
    static let inbound = Color(light: Color(red: 0.18, green: 0.42, blue: 0.60),
                               dark: Color(red: 0.46, green: 0.70, blue: 0.92))
    static let outbound = Color(light: Color(red: 0.72, green: 0.45, blue: 0.14),
                                dark: Color(red: 0.94, green: 0.72, blue: 0.38))
}

private extension Color {
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
    }
}

private func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .monospaced)
}

// MARK: - Formatting

private enum Fmt {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    static func bytes(_ value: UInt64) -> String {
        var scaled = Double(value)
        var unit = 0
        while scaled >= 1024, unit < units.count - 1 { scaled /= 1024; unit += 1 }
        return unit == 0 ? "\(value) B" : String(format: scaled >= 100 ? "%.0f %@" : "%.1f %@", scaled, units[unit])
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond >= 1 else { return "0 B/s" }
        return "\(bytes(UInt64(bytesPerSecond)))/s"
    }
}

// MARK: - Timeline

struct MetricsEntry: TimelineEntry {
    let date: Date
    let snapshot: MetricsSnapshot
}

struct MetricsProvider: TimelineProvider {
    func placeholder(in _: Context) -> MetricsEntry {
        MetricsEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in _: Context, completion: @escaping (MetricsEntry) -> Void) {
        completion(MetricsEntry(date: Date(), snapshot: load()))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<MetricsEntry>) -> Void) {
        // The app nudges WidgetKit (reloadAllTimelines) whenever it writes fresh
        // metrics; this short policy is just a fallback so the widget still ages
        // its data if the app stops running.
        let entry = MetricsEntry(date: Date(), snapshot: load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60))))
    }

    private func load() -> MetricsSnapshot {
        SharedMetricsStore.defaultURL().flatMap(SharedMetricsStore.read) ?? .empty
    }
}

private extension MetricsSnapshot {
    /// A representative snapshot for the gallery/placeholder.
    static let preview = MetricsSnapshot(
        activeConnections: 24, totalConnections: 58,
        bytesIn: 2_415_919_104, bytesOut: 188_743_680,
        throughputIn: 1_310_720, throughputOut: 65536,
        topApps: [
            .init(name: "Safari", bytes: 1_073_741_824),
            .init(name: "Spotify", bytes: 268_435_456),
            .init(name: "Mail", bytes: 67_108_864)
        ],
        updatedAt: Date()
    )

    var isLive: Bool { activeConnections > 0 || throughputIn > 0 || throughputOut > 0 }
}

// MARK: - Shared components

private struct Header: View {
    let snapshot: MetricsSnapshot
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(snapshot.isLive ? Palette.accent : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
            Text("MatrixNet")
                .font(.system(size: compact ? 11 : 12, weight: .semibold))
                .tracking(0.3)
            Spacer(minLength: 0)
            if !compact {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.accent)
            }
        }
    }
}

/// A throughput readout: arrow + rate, with an optional session total beneath.
private struct RateView: View {
    let systemImage: String
    let rate: Double
    let session: UInt64
    let tint: Color
    var showSession = true

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Image(systemName: systemImage).font(.system(size: 9, weight: .bold)).foregroundStyle(tint)
                Text(Fmt.rate(rate)).font(mono(12, .medium)).foregroundStyle(.primary)
            }
            if showSession {
                Text(Fmt.bytes(session)).font(mono(9)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct CountBlock: View {
    let value: Int
    let total: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(value)")
                .font(mono(30, .semibold)).foregroundStyle(Palette.accent)
                .minimumScaleFactor(0.6).lineLimit(1)
            VStack(alignment: .leading, spacing: 0) {
                Text("active").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Text("of \(total)").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
    }
}

private struct TopAppRow: View {
    let app: MetricsSnapshot.TopApp
    let maxBytes: UInt64

    var body: some View {
        HStack(spacing: 6) {
            Text(app.name).font(.system(size: 10)).lineLimit(1).frame(width: 78, alignment: .leading)
            GeometryReader { geo in
                Capsule().fill(Palette.accent.opacity(0.15))
                    .overlay(alignment: .leading) {
                        Capsule().fill(Palette.accent.opacity(0.85))
                            .frame(width: max(2, geo.size.width * fraction))
                    }
            }
            .frame(height: 4)
            Text(Fmt.bytes(app.bytes)).font(mono(9)).foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }

    private var fraction: CGFloat {
        guard maxBytes > 0 else { return 0 }
        return CGFloat(Double(app.bytes) / Double(maxBytes))
    }
}

// MARK: - Family views

private struct SmallWidget: View {
    let snapshot: MetricsSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(snapshot: snapshot, compact: true)
            Spacer(minLength: 4)
            CountBlock(value: snapshot.activeConnections, total: snapshot.totalConnections)
            Spacer(minLength: 6)
            Divider().opacity(0.4)
            Spacer(minLength: 6)
            HStack {
                RateView(systemImage: "arrow.down", rate: snapshot.throughputIn,
                         session: snapshot.bytesIn, tint: Palette.inbound)
                Spacer(minLength: 8)
                RateView(systemImage: "arrow.up", rate: snapshot.throughputOut,
                         session: snapshot.bytesOut, tint: Palette.outbound)
            }
        }
    }
}

private struct MediumWidget: View {
    let snapshot: MetricsSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Header(snapshot: snapshot)
                Spacer(minLength: 6)
                CountBlock(value: snapshot.activeConnections, total: snapshot.totalConnections)
                Spacer(minLength: 8)
                RateView(systemImage: "arrow.down", rate: snapshot.throughputIn,
                         session: snapshot.bytesIn, tint: Palette.inbound)
                Spacer(minLength: 4)
                RateView(systemImage: "arrow.up", rate: snapshot.throughputOut,
                         session: snapshot.bytesOut, tint: Palette.outbound)
            }
            .frame(width: 118)

            Rectangle().fill(.quaternary).frame(width: 1)

            VStack(alignment: .leading, spacing: 5) {
                Text("TOP TALKERS").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).tracking(0.5)
                if snapshot.topApps.isEmpty {
                    Spacer()
                    Text("No traffic yet").font(.system(size: 10)).foregroundStyle(.tertiary)
                    Spacer()
                } else {
                    ForEach(snapshot.topApps.prefix(4), id: \.name) { app in
                        TopAppRow(app: app, maxBytes: snapshot.topApps.first?.bytes ?? 1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct LargeWidget: View {
    let snapshot: MetricsSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Header(snapshot: snapshot)
            HStack(spacing: 12) {
                CountBlock(value: snapshot.activeConnections, total: snapshot.totalConnections)
                Spacer()
                RateView(systemImage: "arrow.down", rate: snapshot.throughputIn,
                         session: snapshot.bytesIn, tint: Palette.inbound)
                RateView(systemImage: "arrow.up", rate: snapshot.throughputOut,
                         session: snapshot.bytesOut, tint: Palette.outbound)
            }
            Divider().opacity(0.4)
            Text("TOP TALKERS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).tracking(0.5)
            if snapshot.topApps.isEmpty {
                Spacer()
                Text("No traffic captured yet").font(.system(size: 11)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                ForEach(snapshot.topApps.prefix(5), id: \.name) { app in
                    TopAppRow(app: app, maxBytes: snapshot.topApps.first?.bytes ?? 1)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 4) {
                Image(systemName: "clock").font(.system(size: 8))
                Text("Updated \(snapshot.updatedAt, style: .relative) ago")
                    .font(.system(size: 9))
            }
            .foregroundStyle(.tertiary)
        }
    }
}

struct MatrixNetWidgetView: View {
    var entry: MetricsEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall: SmallWidget(snapshot: entry.snapshot)
        case .systemLarge: LargeWidget(snapshot: entry.snapshot)
        default: MediumWidget(snapshot: entry.snapshot)
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
        .description("Live network activity, throughput, and the apps using your connection.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct MatrixNetWidgetBundle: WidgetBundle {
    var body: some Widget {
        MatrixNetWidget()
    }
}
