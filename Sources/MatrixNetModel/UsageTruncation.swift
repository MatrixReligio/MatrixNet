import Foundation

/// Bounds storage by keeping only the top-N destinations per (hour, app) and
/// folding the long tail into a single synthetic "other" row.
public enum UsageTruncation {
    public static let otherHost = "·other"
    public static let mixedCountry = "—"

    public static func topN(_ rows: [UsageRow], limit: Int) -> [UsageRow] {
        var byApp: [String: [UsageRow]] = [:]
        var order: [String] = []
        for row in rows {
            if byApp[row.app] == nil { order.append(row.app) }
            byApp[row.app, default: []].append(row)
        }
        var result: [UsageRow] = []
        for app in order {
            let group = byApp[app] ?? []
            // Rank only real destinations; a pre-existing "·other" is always part
            // of the tail, so re-running topN is idempotent.
            let named = group.filter { $0.host != otherHost }
            guard named.count > limit else {
                result.append(contentsOf: group)
                continue
            }
            let existingOther = group.filter { $0.host == otherHost }
            let sorted = named.sorted { ($0.bytesIn + $0.bytesOut) > ($1.bytesIn + $1.bytesOut) }
            result.append(contentsOf: sorted.prefix(limit))
            let folded = Array(sorted.dropFirst(limit)) + existingOther
            let inSum = folded.reduce(UInt64(0)) { $0 + $1.bytesIn }
            let outSum = folded.reduce(UInt64(0)) { $0 + $1.bytesOut }
            result.append(UsageRow(
                periodStart: group[0].periodStart,
                app: app,
                host: otherHost,
                country: mixedCountry,
                bytesIn: inSum,
                bytesOut: outSum
            ))
        }
        return result
    }
}
