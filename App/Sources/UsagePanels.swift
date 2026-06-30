import Charts
import MatrixNetGeoIP
import MatrixNetModel
import SwiftUI

// MARK: - Empty state

struct UsageEmptyState: View {
    var body: some View {
        Panel {
            VStack(spacing: 8) {
                Image(systemName: "chart.bar.doc.horizontal")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Gathering usage…")
                    .foregroundStyle(.secondary)
                Text("Usage accrues while monitoring is active.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 180)
        }
    }
}

// MARK: - Hero: totals + trend

struct UsageHero: View {
    let totals: UsageTotals
    let trend: [TrendBucket]
    /// Drives the chart shape: dense hourly samples read best as a smooth area,
    /// while sparse per-day samples are shown as discrete grouped bars so a few
    /// days' totals are never dressed up as a continuous curve.
    let granularity: TrendGranularity

    /// The x-position the pointer is hovering, snapped to the nearest sample for
    /// the readout tooltip.
    @State private var selectedDate: Date?

    private let downLabel = String(localized: "Download")
    private let upLabel = String(localized: "Upload")

    private var selectedBucket: TrendBucket? {
        guard let selectedDate else { return nil }
        return UsageReport.bucket(at: selectedDate, in: trend)
    }

    var body: some View {
        Panel {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                metric("Downloaded", value: totals.bytesIn, tint: Theme.inbound)
                metric("Uploaded", value: totals.bytesOut, tint: Theme.outbound)
                Spacer()
            }
            if trend.count > 1 {
                chart.frame(height: 150)
            }
        }
    }

    private func metric(_ label: LocalizedStringKey, value: UInt64, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(tint)
            Text(verbatim: Format.bytes(value))
                .font(Theme.mono(24, weight: .medium))
                .monospacedDigit()
        }
    }

    private var chart: some View {
        Chart {
            if granularity == .hour {
                hourlyMarks
            } else {
                dailyMarks
            }
            if let selectedBucket {
                RuleMark(x: .value("Time", ruleDate(selectedBucket.start)))
                    .foregroundStyle(Color.primary.opacity(0.15))
                    .annotation(
                        position: .top,
                        spacing: 0,
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                    ) {
                        tooltip(selectedBucket)
                    }
            }
        }
        .chartXSelection(value: $selectedDate)
        .chartForegroundStyleScale([downLabel: Theme.inbound, upLabel: Theme.outbound])
        .chartLegend(position: .top, alignment: .trailing, spacing: 4)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let bytes = value.as(Double.self) {
                        Text(verbatim: bytes < 1 ? "0" : Format.bytes(UInt64(bytes)))
                    }
                }
            }
        }
        .chartXAxis { xAxis }
    }

    /// Smooth filled area + line with visible per-sample points (today's hours).
    @ChartContentBuilder private var hourlyMarks: some ChartContent {
        ForEach(trend, id: \.start) { bucket in
            AreaMark(
                x: .value("Time", bucket.start),
                y: .value("Bytes", bucket.totals.bytesIn),
                series: .value("Direction", downLabel)
            )
            .foregroundStyle(Theme.inbound.opacity(0.18))
            .interpolationMethod(.monotone)
        }
        ForEach(trend, id: \.start) { bucket in
            LineMark(
                x: .value("Time", bucket.start),
                y: .value("Bytes", bucket.totals.bytesIn),
                series: .value("Direction", downLabel)
            )
            .foregroundStyle(by: .value("Direction", downLabel))
            .interpolationMethod(.monotone)
            .symbol(.circle)
            .symbolSize(18)
        }
        ForEach(trend, id: \.start) { bucket in
            LineMark(
                x: .value("Time", bucket.start),
                y: .value("Bytes", bucket.totals.bytesOut),
                series: .value("Direction", upLabel)
            )
            .foregroundStyle(by: .value("Direction", upLabel))
            .interpolationMethod(.monotone)
            .symbol(.circle)
            .symbolSize(18)
        }
    }

    /// Grouped download/upload bars, one pair per day — discrete by construction,
    /// so three days of history read as three bars, not an invented curve.
    @ChartContentBuilder private var dailyMarks: some ChartContent {
        ForEach(trend, id: \.start) { bucket in
            BarMark(
                x: .value("Day", bucket.start, unit: .day),
                y: .value("Bytes", bucket.totals.bytesIn)
            )
            .position(by: .value("Direction", downLabel))
            .foregroundStyle(by: .value("Direction", downLabel))
            BarMark(
                x: .value("Day", bucket.start, unit: .day),
                y: .value("Bytes", bucket.totals.bytesOut)
            )
            .position(by: .value("Direction", upLabel))
            .foregroundStyle(by: .value("Direction", upLabel))
        }
    }

    /// Hour ticks for today; day ticks otherwise — never the auto-picked
    /// 12-hour labels, which imply a sub-day resolution the daily data lacks.
    @AxisContentBuilder private var xAxis: some AxisContent {
        if granularity == .hour {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(format: .dateTime.hour())
            }
        } else {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
    }

    private func tooltip(_ bucket: TrendBucket) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: tooltipDate(bucket.start))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(verbatim: "↓").foregroundStyle(Theme.inbound)
                Text(verbatim: Format.bytes(bucket.totals.bytesIn)).font(Theme.mono(11))
            }
            HStack(spacing: 4) {
                Text(verbatim: "↑").foregroundStyle(Theme.outbound)
                Text(verbatim: Format.bytes(bucket.totals.bytesOut)).font(Theme.mono(11))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }

    /// Where to anchor the hover rule. Hourly points sit on their exact
    /// timestamp; daily bars are centred on the day band, so shift the rule to
    /// the day's midpoint to line up with the bar pair.
    private func ruleDate(_ start: Date) -> Date {
        granularity == .hour ? start : start.addingTimeInterval(43200)
    }

    private func tooltipDate(_ date: Date) -> String {
        granularity == .hour
            ? date.formatted(.dateTime.month(.abbreviated).day().hour())
            : date.formatted(.dateTime.month(.abbreviated).day())
    }
}

// MARK: - Ranked bar row

struct UsageBarRow<Leading: View>: View {
    @ViewBuilder var leading: Leading
    let title: String
    let detail: String
    let value: String
    let fraction: Double
    let tint: Color
    var isSelected: Bool = false
    var onTap: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                leading
                Text(verbatim: title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(title)
                Text(verbatim: value)
                    .font(Theme.mono(11))
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    Capsule().fill(tint.opacity(isSelected ? 0.9 : 0.55))
                        .frame(width: max(2, geometry.size.width * fraction))
                }
            }
            .frame(height: 6)
            if !detail.isEmpty {
                Text(verbatim: detail)
                    .font(Theme.mono(10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }
}

private func detailText(_ totals: UsageTotals) -> String {
    "↓ \(Format.bytes(totals.bytesIn))  ↑ \(Format.bytes(totals.bytesOut))"
}

private func combined(_ totals: UsageTotals) -> UInt64 {
    totals.bytesIn + totals.bytesOut
}

// MARK: - By app

struct UsageAppRanking: View {
    let items: [AppUsage]
    @Binding var selectedApp: String?
    @Environment(AppModel.self) private var model

    /// Best-effort app-name → icon map from the live connection set (a historical
    /// app may no longer be running, in which case the row shows a generic mark).
    private var icons: [String: NSImage] {
        var icons: [String: NSImage] = [:]
        for connection in model.connections {
            let name = connection.app.displayName
            if icons[name] == nil, let icon = AppIconResolver.shared.cachedIcon(for: connection.app) {
                icons[name] = icon
            }
        }
        return icons
    }

    var body: some View {
        Panel {
            let icons = icons
            let maxValue = items.map { combined($0.totals) }.max() ?? 1
            ForEach(items, id: \.app) { item in
                UsageBarRow(
                    leading: { icon(for: item.app, icons: icons) },
                    title: item.app,
                    detail: detailText(item.totals),
                    value: Format.bytes(combined(item.totals)),
                    fraction: Double(combined(item.totals)) / Double(max(1, maxValue)),
                    tint: Theme.accent,
                    isSelected: selectedApp == item.app,
                    onTap: { selectedApp = selectedApp == item.app ? nil : item.app }
                )
            }
            if selectedApp != nil {
                Text("Tap the selected app again to clear the filter.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func icon(for app: String, icons: [String: NSImage]) -> some View {
        if let image = icons[app] {
            Image(nsImage: image).resizable().frame(width: 16, height: 16)
        } else {
            Image(systemName: "app.dashed").foregroundStyle(.secondary).frame(width: 16, height: 16)
        }
    }
}

// MARK: - By country

struct UsageCountryRanking: View {
    let items: [CountryUsage]

    var body: some View {
        Panel {
            let maxValue = items.map { combined($0.totals) }.max() ?? 1
            ForEach(items, id: \.country) { item in
                UsageBarRow(
                    leading: { Text(verbatim: flag(item.country)) },
                    title: name(item.country),
                    detail: detailText(item.totals),
                    value: Format.bytes(combined(item.totals)),
                    fraction: Double(combined(item.totals)) / Double(max(1, maxValue)),
                    tint: Theme.inbound
                )
            }
        }
    }

    private func flag(_ code: String) -> String {
        GeoIPDatabase.flag(for: code) ?? "🌐"
    }

    private func name(_ code: String) -> String {
        guard !code.isEmpty, code != UsageTruncation.mixedCountry else { return String(localized: "Unknown") }
        return Locale.current.localizedString(forRegionCode: code) ?? code
    }
}

// MARK: - By domain

struct UsageDomainRanking: View {
    let items: [DomainUsage]

    var body: some View {
        Panel {
            let maxValue = items.map { combined($0.totals) }.max() ?? 1
            ForEach(items, id: \.host) { item in
                UsageBarRow(
                    leading: { EmptyView() },
                    title: label(item.host),
                    detail: detailText(item.totals),
                    value: Format.bytes(combined(item.totals)),
                    fraction: Double(combined(item.totals)) / Double(max(1, maxValue)),
                    tint: Theme.outbound
                )
            }
        }
    }

    private func label(_ host: String) -> String {
        host == UsageTruncation.otherHost ? String(localized: "Other") : host
    }
}
