import MatrixNetModel
import SwiftUI

/// The Usage tab: "where did my bandwidth go" — total throughput plus the top
/// apps, countries, and domains by bytes over a selectable reporting window.
struct UsageView: View {
    @Environment(AppModel.self) private var model
    @State private var choice: PeriodChoice = .last7Days
    @State private var dimension: Dimension = .app
    @State private var selectedApp: String?

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
        case .cycle: .currentCycle(resetDay: Preferences(defaults: .standard).billingCycleResetDay)
        }
    }

    private var rows: [UsageRow] {
        model.usageRows(for: period)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Period", selection: $choice) {
                    ForEach(PeriodChoice.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                let rows = rows
                if rows.isEmpty {
                    UsageEmptyState()
                } else {
                    UsageHero(
                        totals: UsageReport.totals(rows),
                        trend: UsageReport.trend(rows, by: period.trendGranularity, calendar: .current),
                        granularity: period.trendGranularity
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
    }

    @ViewBuilder
    private func breakdown(for rows: [UsageRow]) -> some View {
        switch dimension {
        case .app:
            UsageAppRanking(items: UsageReport.byApp(rows), selectedApp: $selectedApp, icons: iconsByApp())
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

    /// Best-effort app-name → icon map from the live connection set (a historical
    /// app may no longer be running, in which case the list shows a generic mark).
    private func iconsByApp() -> [String: NSImage] {
        var icons: [String: NSImage] = [:]
        for connection in model.connections {
            let name = connection.app.displayName
            if icons[name] == nil, let icon = AppIconResolver.shared.cachedIcon(for: connection.app) {
                icons[name] = icon
            }
        }
        return icons
    }
}
