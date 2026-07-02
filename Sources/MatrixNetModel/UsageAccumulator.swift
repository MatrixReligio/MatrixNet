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

    /// Deltas across the two usage sources (packet capture and NetworkStatistics),
    /// each measured against its *own* baseline. The two sources observe the same
    /// wire traffic with different counters, so a merged baseline would
    /// double-count or freeze a key whenever the preferred source flips at a
    /// capture start/stop boundary. Per key:
    ///  - covered by the packet source → its packet delta is persisted and its
    ///    NStat delta is suppressed (the NStat baseline still advances via
    ///    `nstatCurrent`, so nothing is re-counted after capture stops);
    ///  - NStat-only → its NStat delta is persisted, except the tunnel relay
    ///    while capturing (each app's real bytes already arrive on the tunnel
    ///    side, so the relay would double-represent them);
    ///  - not capturing (no packet keys) → pure NStat pass-through, tunnel
    ///    included, since it is the only record of that traffic.
    public static func sourcedDeltas(
        packetPrevious: [String: UsageTotals],
        packetCurrent: [String: UsageTotals],
        nstatPrevious: [String: UsageTotals],
        nstatCurrent: [String: UsageTotals],
        isTunnelKey: (String) -> Bool
    ) -> [String: UsageTotals] {
        var result = deltas(previous: packetPrevious, current: packetCurrent)
        let capturing = !packetCurrent.isEmpty
        for (key, delta) in deltas(previous: nstatPrevious, current: nstatCurrent) {
            guard packetCurrent[key] == nil else { continue }
            if capturing, isTunnelKey(key) { continue }
            result[key] = delta
        }
        return result
    }
}
