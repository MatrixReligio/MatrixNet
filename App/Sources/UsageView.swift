import MatrixNetModel
import SwiftUI
import UniformTypeIdentifiers

/// The Usage tab: "where did my bandwidth go" — total throughput plus the top
/// apps, countries, and domains by bytes over a selectable reporting window.
struct UsageView: View {
    @Environment(AppModel.self) private var model
    @State private var choice: PeriodChoice = .last7Days
    @State private var dimension: Dimension = .app
    @State private var selectedApp: String?
    @State private var mode: ViewMode = .breakdown

    /// Whether the tab shows the ranked totals or the per-app activity timeline.
    enum ViewMode: String, CaseIterable, Identifiable {
        case breakdown, timeline
        var id: String {
            rawValue
        }

        var title: LocalizedStringKey {
            switch self {
            case .breakdown: "Usage"
            case .timeline: "Timeline"
            }
        }
    }

    /// The selectable reporting windows (mapped to `UsagePeriod`, resolving the
    /// billing cycle from the user's reset-day preference).
    enum PeriodChoice: String, CaseIterable, Identifiable {
        case today, last7Days, last30Days, cycle
        var id: String {
            rawValue
        }

        var title: LocalizedStringKey {
            switch self {
            case .today: "Today"
            case .last7Days: "7 Days"
            case .last30Days: "30 Days"
            case .cycle: "Cycle"
            }
        }
    }

    /// The breakdown axis for the ranked list.
    enum Dimension: String, CaseIterable, Identifiable {
        case app, country, domain
        var id: String {
            rawValue
        }

        var title: LocalizedStringKey {
            switch self {
            case .app: "By App"
            case .country: "By Country"
            case .domain: "By Domain"
            }
        }
    }

    private var period: UsagePeriod {
        switch choice {
        case .today: .today
        case .last7Days: .last7Days
        case .last30Days: .last30Days
        case .cycle:
            .currentCycle(
                resetDay: Preferences(defaults: SharedMetricsStore.sharedDefaults ?? .standard)
                    .billingCycleResetDay
            )
        }
    }

    /// Fetched once per period change and refreshed on a slow timer, rather than
    /// re-querying SwiftData on every body pass (the model publishes ~1 Hz).
    @State private var rows: [UsageRow] = []
    /// The activity timeline for the current period, refreshed alongside `rows`.
    @State private var timeline = ActivityTimeline(hours: [], rows: [])

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Period", selection: $choice) {
                    ForEach(PeriodChoice.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Picker("View", selection: $mode) {
                    ForEach(ViewMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if mode == .timeline {
                    ActivityTimelineView(timeline: timeline)
                } else if rows.isEmpty {
                    UsageEmptyState()
                } else {
                    UsageHero(
                        totals: UsageReport.totals(rows),
                        trend: UsageReport.trend(rows, by: period.trendGranularity, calendar: .current)
                    )

                    Picker("Breakdown", selection: $dimension) {
                        ForEach(Dimension.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    breakdown(for: rows)
                }
            }
            .padding(20)
        }
        .navigationTitle(Text("Usage"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Export as CSV") { export(.csv) }
                    Button("Export as JSON") { export(.json) }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(rows.isEmpty)
            }
        }
        .task(id: choice) {
            while !Task.isCancelled {
                rows = model.usageRows(for: period)
                timeline = model.activityTimeline(period: period)
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private enum ExportFormat { case csv, json }

    private func export(_ format: ExportFormat) {
        let panel = NSSavePanel()
        let ext = format == .csv ? "csv" : "json"
        panel.nameFieldStringValue = "usage.\(ext)"
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = format == .csv ? UsageExport.csv(rows) : UsageExport.json(rows)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    @ViewBuilder
    private func breakdown(for rows: [UsageRow]) -> some View {
        switch dimension {
        case .app:
            UsageAppRanking(items: UsageReport.byApp(rows), selectedApp: $selectedApp)
        case .country:
            UsageCountryRanking(items: UsageReport.byCountry(scoped(rows)))
        case .domain:
            UsageDomainRanking(items: UsageReport.byDomain(scoped(rows), app: selectedApp))
        }
    }

    /// When an app is selected, country/domain breakdowns scope to it.
    private func scoped(_ rows: [UsageRow]) -> [UsageRow] {
        guard let selectedApp else { return rows }
        return rows.filter { $0.app == selectedApp }
    }
}
