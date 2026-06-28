import Foundation

public struct AppUsage: Sendable, Equatable {
    public let app: String
    public let totals: UsageTotals
}

public struct CountryUsage: Sendable, Equatable {
    public let country: String
    public let totals: UsageTotals
}

public struct DomainUsage: Sendable, Equatable {
    public let host: String
    public let totals: UsageTotals
}

public struct TrendBucket: Sendable, Equatable {
    public let start: Date
    public let totals: UsageTotals
}

/// Pure aggregations over a fetched set of hourly usage rows.
public enum UsageReport {
    public static func totals(_ rows: [UsageRow]) -> UsageTotals {
        rows.reduce(UsageTotals()) { $0 + UsageTotals(bytesIn: $1.bytesIn, bytesOut: $1.bytesOut) }
    }

    public static func byApp(_ rows: [UsageRow]) -> [AppUsage] {
        group(rows, key: \.app)
            .map { AppUsage(app: $0.key, totals: $0.value) }
            .sorted { total($0.totals) > total($1.totals) }
    }

    public static func byCountry(_ rows: [UsageRow]) -> [CountryUsage] {
        group(rows, key: \.country)
            .map { CountryUsage(country: $0.key, totals: $0.value) }
            .sorted { total($0.totals) > total($1.totals) }
    }

    public static func byDomain(_ rows: [UsageRow], app: String?) -> [DomainUsage] {
        let filtered = app.map { name in rows.filter { $0.app == name } } ?? rows
        return group(filtered, key: \.host)
            .map { DomainUsage(host: $0.key, totals: $0.value) }
            .sorted { total($0.totals) > total($1.totals) }
    }

    public static func trend(
        _ rows: [UsageRow],
        by granularity: TrendGranularity,
        calendar: Calendar
    ) -> [TrendBucket] {
        var buckets: [Date: UsageTotals] = [:]
        for row in rows {
            let key = granularity == .hour
                ? UsageBucketing.hourStart(of: row.periodStart, calendar: calendar)
                : calendar.startOfDay(for: row.periodStart)
            buckets[key, default: UsageTotals()] = buckets[key, default: UsageTotals()]
                + UsageTotals(bytesIn: row.bytesIn, bytesOut: row.bytesOut)
        }
        return buckets
            .map { TrendBucket(start: $0.key, totals: $0.value) }
            .sorted { $0.start < $1.start }
    }

    private static func total(_ totals: UsageTotals) -> UInt64 {
        totals.bytesIn + totals.bytesOut
    }

    private static func group(_ rows: [UsageRow], key: (UsageRow) -> String) -> [String: UsageTotals] {
        var out: [String: UsageTotals] = [:]
        for row in rows {
            out[key(row), default: UsageTotals()] = out[key(row), default: UsageTotals()]
                + UsageTotals(bytesIn: row.bytesIn, bytesOut: row.bytesOut)
        }
        return out
    }
}
