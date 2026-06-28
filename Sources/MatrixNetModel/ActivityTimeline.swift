import Foundation

/// One app's network activity over a fixed bucket scale: `buckets[i]` is the
/// total bytes in `ActivityTimeline.hours[i]`. `total` is their sum.
public struct AppActivityRow: Sendable, Equatable {
    public let app: String
    public let buckets: [UInt64]
    public let total: UInt64

    public init(app: String, buckets: [UInt64], total: UInt64) {
        self.app = app
        self.buckets = buckets
        self.total = total
    }
}

/// A per-app activity timeline aligned to a shared list of bucket start dates.
public struct ActivityTimeline: Sendable, Equatable {
    public let hours: [Date]
    public let rows: [AppActivityRow]

    public init(hours: [Date], rows: [AppActivityRow]) {
        self.hours = hours
        self.rows = rows
    }
}

/// Builds an `ActivityTimeline` from hourly usage rows and an explicit bucket
/// scale. Pure: the caller supplies `hours` (the bucket start dates, ascending
/// with a uniform step), so the same builder serves hourly (Today) and daily
/// (multi-day) windows.
public enum ActivityTimelineBuilder {
    public static func build(rows: [UsageRow], hours: [Date]) -> ActivityTimeline {
        guard !hours.isEmpty else { return ActivityTimeline(hours: hours, rows: []) }
        // The last bucket's span equals the final gap (or 1h for a lone bucket),
        // bounding what counts as "within" the timeline.
        let lastStep = hours.count > 1 ? hours[hours.count - 1].timeIntervalSince(hours[hours.count - 2]) : 3600
        let end = hours[hours.count - 1].addingTimeInterval(lastStep)

        var series: [String: [UInt64]] = [:]
        for row in rows {
            guard row.periodStart >= hours[0], row.periodStart < end else { continue }
            // Find the bucket by boundary, not a fixed step, so uneven grids
            // (e.g. a daily window crossing a DST change) place every row exactly.
            guard let index = bucketIndex(for: row.periodStart, in: hours) else { continue }
            var buckets = series[row.app] ?? [UInt64](repeating: 0, count: hours.count)
            buckets[index] &+= row.bytesIn &+ row.bytesOut
            series[row.app] = buckets
        }

        var appRows: [AppActivityRow] = []
        for (app, buckets) in series {
            var total: UInt64 = 0
            for value in buckets {
                total &+= value
            }
            guard total > 0 else { continue }
            appRows.append(AppActivityRow(app: app, buckets: buckets, total: total))
        }
        appRows.sort { $0.total != $1.total ? $0.total > $1.total : $0.app < $1.app }

        return ActivityTimeline(hours: hours, rows: appRows)
    }

    /// The index of the bucket containing `date` — the last bucket whose start is
    /// `<= date`, found by binary search (callers guarantee `date >= hours[0]`).
    private static func bucketIndex(for date: Date, in hours: [Date]) -> Int? {
        var low = 0
        var high = hours.count - 1
        var result: Int?
        while low <= high {
            let mid = (low + high) / 2
            if hours[mid] <= date {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }
}
