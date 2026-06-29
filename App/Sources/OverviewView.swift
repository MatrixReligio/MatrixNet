import Charts
import MatrixNetGeoIP
import MatrixNetModel
import SwiftUI

/// An instrument dashboard: a live throughput chart, a strip of headline metrics,
/// the busiest apps, and protocol/destination breakdowns.
struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ThroughputChart(
                    samples: model.throughputHistory.values,
                    inRate: model.throughputIn,
                    outRate: model.throughputOut
                )
                kpiStrip
                HStack(alignment: .top, spacing: 16) {
                    TopTalkersPanel(talkers: model.topTalkers)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(spacing: 16) {
                        ProtocolMixPanel(mix: model.protocolMix)
                        DestinationCountriesPanel(countries: model.destinationCountries)
                    }
                    .frame(width: 280)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Overview")
        .background(.background)
    }

    private var kpiStrip: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
        return LazyVGrid(columns: columns, spacing: 12) {
            StatTile(
                label: "Active",
                value: "\(model.activeCount)",
                detail: "\(model.connections.count) total",
                tint: Theme.accent
            )
            StatTile(
                label: "Session total",
                value: Format.bytes(model.sessionBytesIn &+ model.sessionBytesOut),
                detail: "↓\(Format.bytes(model.sessionBytesIn)) ↑\(Format.bytes(model.sessionBytesOut))",
                tint: Theme.inbound
            )
            StatTile(
                label: "Active apps",
                value: "\(model.activeAppCount)",
                detail: "processes",
                tint: Theme.accent
            )
            StatTile(
                label: "Countries",
                value: "\(model.countriesReached)",
                detail: "reached",
                tint: Theme.inbound
            )
            StatTile(
                label: "Threats",
                value: "\(model.threatCount)",
                detail: "flagged remotes",
                tint: Theme.danger
            )
            StatTile(
                label: "Via proxy",
                value: "\(Int((model.proxyShare * 100).rounded()))%",
                detail: "of active",
                tint: Theme.advisory
            )
        }
    }
}

// MARK: - Throughput chart

private struct ThroughputChart: View {
    let samples: [ThroughputSample]
    let inRate: Double
    let outRate: Double
    @State private var selectedTime: Date?

    private var selectedSample: ThroughputSample? {
        guard let selectedTime else { return nil }
        return samples.min {
            abs($0.time.timeIntervalSince(selectedTime)) < abs($1.time.timeIntervalSince(selectedTime))
        }
    }

    var body: some View {
        Panel {
            HStack(alignment: .firstTextBaseline) {
                Text("Throughput · last minute")
                    .font(.headline)
                Spacer()
                Text(verbatim: "↓ \(Format.rate(inRate))")
                    .foregroundStyle(Theme.inbound)
                Text(verbatim: "↑ \(Format.rate(outRate))")
                    .foregroundStyle(Theme.outbound)
            }
            .font(Theme.mono(12, weight: .medium))

            if samples.count < 2 {
                Text("Gathering throughput…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(height: 160, alignment: .center)
                    .frame(maxWidth: .infinity)
            } else {
                chart.frame(height: 160)
            }
        }
    }

    /// Width of the live window in seconds (≈ 60 samples at 1 Hz).
    private let windowSeconds: TimeInterval = 60

    private var chart: some View {
        let latest = samples.last?.time ?? Date()
        let ticks = ThroughputAxis.tickDates(latest: latest, window: windowSeconds, count: 5)
        let downLabel = String(localized: "Download")
        let upLabel = String(localized: "Upload")
        return Chart {
            // Inbound area (no legend entry).
            ForEach(samples, id: \.time) { sample in
                AreaMark(x: .value("Time", sample.time), y: .value("Rate", sample.inRate))
                    .foregroundStyle(
                        .linearGradient(
                            colors: [Theme.inbound.opacity(0.22), Theme.inbound.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.monotone)
            }
            // Two distinct series → distinct colors + a legend.
            ForEach(samples, id: \.time) { sample in
                LineMark(
                    x: .value("Time", sample.time),
                    y: .value("Rate", sample.inRate),
                    series: .value("Direction", downLabel)
                )
                .foregroundStyle(by: .value("Direction", downLabel))
                .interpolationMethod(.monotone)
            }
            ForEach(samples, id: \.time) { sample in
                LineMark(
                    x: .value("Time", sample.time),
                    y: .value("Rate", sample.outRate),
                    series: .value("Direction", upLabel)
                )
                .foregroundStyle(by: .value("Direction", upLabel))
                .interpolationMethod(.monotone)
            }
            if let selectedSample {
                RuleMark(x: .value("Time", selectedSample.time))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                    .annotation(
                        position: .top,
                        spacing: 4,
                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .plot))
                    ) {
                        tooltip(selectedSample)
                    }
                PointMark(x: .value("Time", selectedSample.time), y: .value("Rate", selectedSample.inRate))
                    .foregroundStyle(Theme.inbound)
                PointMark(x: .value("Time", selectedSample.time), y: .value("Rate", selectedSample.outRate))
                    .foregroundStyle(Theme.outbound)
            }
        }
        .chartForegroundStyleScale([downLabel: Theme.inbound, upLabel: Theme.outbound])
        .chartLegend(position: .top, alignment: .trailing, spacing: 4)
        // Clip the plot so the smooth (monotone) area/line can't overshoot past
        // the left/right edge of the coordinate space and spill outside the axes.
        .chartPlotStyle { $0.clipped() }
        .chartXSelection(value: $selectedTime)
        // Pin "now" to the right edge with a stable 60s window so the axis reads
        // 60s … 15s … now left to right.
        .chartXScale(domain: latest.addingTimeInterval(-windowSeconds) ... latest)
        .chartXAxis {
            AxisMarks(values: ticks) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        let seconds = ThroughputAxis.secondsAgo(of: date, relativeTo: latest)
                        if seconds == 0 {
                            Text("now")
                        } else {
                            Text(verbatim: "\(seconds)s")
                        }
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let rate = value.as(Double.self) {
                        Text(verbatim: rate < 1 ? "0" : Format.rate(rate))
                    }
                }
            }
        }
    }

    private func tooltip(_ sample: ThroughputSample) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: ThroughputAxis.clockLabel(for: sample.time))
                .font(.caption2).foregroundStyle(.secondary)
            Text(verbatim: "↓ \(Format.rate(sample.inRate))")
                .foregroundStyle(Theme.inbound)
            Text(verbatim: "↑ \(Format.rate(sample.outRate))")
                .foregroundStyle(Theme.outbound)
        }
        .font(Theme.mono(11))
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Top Talkers

private struct TopTalkersPanel: View {
    let talkers: [TopTalker]

    var body: some View {
        Panel {
            Text("Top Talkers").font(.headline)
            if talkers.isEmpty {
                Text("No traffic yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(talkers) { talker in
                    TopTalkerRow(talker: talker, maxBytes: talkers.first?.bytes ?? 1)
                }
            }
        }
    }
}

private struct TopTalkerRow: View {
    let talker: TopTalker
    let maxBytes: UInt64

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = AppIconResolver.shared.cachedIcon(for: talker.app) {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "terminal").foregroundStyle(.secondary)
                }
            }
            .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if let flag = talker.flag {
                        Text(verbatim: flag)
                    }
                    Text(talker.app.displayName).lineLimit(1)
                    if talker.isTunnel {
                        Image(systemName: "shield.lefthalf.filled")
                            .foregroundStyle(Theme.advisory).font(.caption2)
                    }
                    if talker.isThreat {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.danger).font(.caption2)
                    }
                }
                .font(.callout)
                bar
            }

            VStack(alignment: .trailing, spacing: 3) {
                Text(Format.bytes(talker.bytes))
                    .font(Theme.mono(11)).monospacedDigit()
                if talker.connectionCount > 0 {
                    Text("\(talker.connectionCount) conn")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 78, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }

    private var bar: some View {
        GeometryReader { geometry in
            Capsule()
                .fill((talker.isThreat ? Theme.danger : Theme.accent).opacity(0.16))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(talker.isThreat ? Theme.danger : Theme.accent)
                        .frame(width: geometry.size.width * fraction)
                }
        }
        .frame(height: 5)
    }

    private var fraction: Double {
        guard maxBytes > 0 else { return 0 }
        return max(0.02, Double(talker.bytes) / Double(maxBytes))
    }
}

// MARK: - Protocol mix

private struct ProtocolMixPanel: View {
    let mix: [ProtocolShare]

    var body: some View {
        Panel {
            Text("Protocol mix").font(.headline)
            if mix.isEmpty {
                Text("No active connections.")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 6)
            } else {
                HStack(spacing: 14) {
                    Chart(mix, id: \.label) { share in
                        SectorMark(
                            angle: .value("Share", share.share),
                            innerRadius: .ratio(0.62),
                            angularInset: 1.5
                        )
                        .cornerRadius(3)
                        .foregroundStyle(Self.color(for: share.label))
                    }
                    .frame(width: 84, height: 84)

                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(mix, id: \.label) { share in
                            HStack(spacing: 6) {
                                Circle().fill(Self.color(for: share.label)).frame(width: 8, height: 8)
                                Text(verbatim: share.label).font(.caption)
                                Spacer()
                                Text(verbatim: "\(Int((share.share * 100).rounded()))%")
                                    .font(Theme.mono(11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    static func color(for label: String) -> Color {
        switch label {
        case "TLS": Theme.accent
        case "QUIC": Theme.inbound
        case "DNS": Theme.outbound
        case "HTTP": Theme.advisory
        default: Color.secondary
        }
    }
}

// MARK: - Destination countries

private struct DestinationCountriesPanel: View {
    let countries: [CountryActivity]

    var body: some View {
        Panel {
            Text("Destinations").font(.headline)
            if countries.isEmpty {
                Text("No located traffic.")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 6)
            } else {
                let maxCount = countries.first?.connections ?? 1
                ForEach(Array(countries.prefix(5)), id: \.country) { entry in
                    HStack(spacing: 8) {
                        Text(verbatim: GeoIPDatabase.flag(for: entry.country) ?? "🏳️")
                        Text(verbatim: Locale.current.localizedString(forRegionCode: entry.country) ?? entry.country)
                            .font(.caption).lineLimit(1).frame(width: 78, alignment: .leading)
                        GeometryReader { geometry in
                            Capsule().fill(Theme.inbound.opacity(0.16))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(Theme.inbound)
                                        .frame(width: geometry.size.width * fraction(entry.connections, maxCount))
                                }
                        }
                        .frame(height: 5)
                        Text(verbatim: "\(entry.connections)")
                            .font(Theme.mono(10)).foregroundStyle(.secondary)
                            .frame(width: 22, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func fraction(_ count: Int, _ maxCount: Int) -> Double {
        guard maxCount > 0 else { return 0 }
        return max(0.04, Double(count) / Double(maxCount))
    }
}

// MARK: - Shared chrome

private struct StatTile: View {
    let label: LocalizedStringKey
    let value: String
    var detail: LocalizedStringKey?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(tint)
            Text(verbatim: value)
                .font(Theme.mono(22, weight: .medium))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
