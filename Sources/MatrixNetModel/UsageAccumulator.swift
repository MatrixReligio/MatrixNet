import Foundation

/// Turns successive cumulative (monotonic) snapshots into per-key positive
/// deltas. A counter reset or a brand-new key is handled by treating the current
/// value as the delta; keys whose two deltas are both zero are omitted.
public enum UsageAccumulator {
    public static func deltas(
        previous: [String: UsageTotals],
        current: [String: UsageTotals]
    ) -> [String: UsageTotals] {
        var result: [String: UsageTotals] = [:]
        for (key, now) in current {
            let was = previous[key] ?? UsageTotals()
            let deltaIn = now.bytesIn >= was.bytesIn ? now.bytesIn - was.bytesIn : now.bytesIn
            let deltaOut = now.bytesOut >= was.bytesOut ? now.bytesOut - was.bytesOut : now.bytesOut
            if deltaIn > 0 || deltaOut > 0 {
                result[key] = UsageTotals(bytesIn: deltaIn, bytesOut: deltaOut)
            }
        }
        return result
    }
}
