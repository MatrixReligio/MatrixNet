import Foundation
import MatrixNetCapture
import MatrixNetModel
import MatrixNetStore

/// Usage-tab persistence: diffing the aggregator's monotonic per-flow totals into
/// hourly buckets, the launch-time retention sweep, and the forced final flush on
/// stop/terminate. Split out of AppModel so that file stays focused.
extension AppModel {
    /// Diffs the aggregator's monotonic per-flow usage totals and persists the
    /// positive growth into hourly buckets. Throttled to ≈ 30s, with the prior
    /// hour compacted to its top destinations once it rolls over.
    func flushUsage(now: Date) async {
        guard let usageStore, now.timeIntervalSince(lastUsageFlush) >= 30 else { return }
        lastUsageFlush = now
        await persistUsage(usageStore: usageStore, now: now)
    }

    /// Forces a usage flush regardless of the 30s throttle, so the final
    /// sub-interval of usage is persisted when monitoring stops or the app quits
    /// (otherwise a pause, a quit, or a session shorter than 30s loses it).
    func flushUsageNow() async {
        guard let usageStore else { return }
        lastUsageFlush = Date()
        await persistUsage(usageStore: usageStore, now: Date())
    }

    private func persistUsage(usageStore: UsageStore, now: Date) async {
        // Diff each source against its own baseline: the packet overlay and the
        // NStat totals count the same wire traffic with different counters, so a
        // merged baseline would double-count or freeze keys whenever capture
        // starts or stops (see UsageAccumulator.sourcedDeltas).
        let sources = await aggregator.usageSnapshotBySource()
        var packetCurrent: [String: UsageTotals] = [:]
        var nstatCurrent: [String: UsageTotals] = [:]
        var meta: [String: ConnectionAggregator.UsageFlowTotal] = [:]
        for flow in sources.nstat {
            let key = "\(flow.app)\u{1F}\(flow.address.description)"
            nstatCurrent[key] = UsageTotals(bytesIn: flow.bytesIn, bytesOut: flow.bytesOut)
            meta[key] = flow
        }
        for flow in sources.packet {
            let key = "\(flow.app)\u{1F}\(flow.address.description)"
            packetCurrent[key] = UsageTotals(bytesIn: flow.bytesIn, bytesOut: flow.bytesOut)
            meta[key] = flow
        }
        let deltas = UsageAccumulator.sourcedDeltas(
            packetPrevious: lastUsageSeenPacket,
            packetCurrent: packetCurrent,
            nstatPrevious: lastUsageSeenNStat,
            nstatCurrent: nstatCurrent,
            isTunnelKey: { key in
                TunnelProcess.isTunnel(String(key.prefix(while: { $0 != "\u{1F}" })))
            }
        )
        let hour = UsageBucketing.hourStart(of: now, calendar: .current)
        var merged: [String: UsageRow] = [:]
        for (key, delta) in deltas {
            guard let flow = meta[key] else { continue }
            let host = resolvedHostnames[flow.address.description] ?? flow.address.description
            let country = GeoIP.country(for: flow.address) ?? ""
            let rowKey = "\(flow.app)\u{1F}\(host)\u{1F}\(country)"
            if var row = merged[rowKey] {
                row.bytesIn += delta.bytesIn
                row.bytesOut += delta.bytesOut
                merged[rowKey] = row
            } else {
                merged[rowKey] = UsageRow(
                    periodStart: hour,
                    app: flow.app,
                    host: host,
                    country: country,
                    bytesIn: delta.bytesIn,
                    bytesOut: delta.bytesOut
                )
            }
        }
        // Advance the baseline only after a durable write (or when there's nothing
        // to write); a failed save keeps the old baseline so the next flush retries
        // this interval's growth instead of silently dropping those bytes.
        if merged.isEmpty || (try? usageStore.accumulate(Array(merged.values))) != nil {
            lastUsageSeenPacket = packetCurrent
            lastUsageSeenNStat = nstatCurrent
        }

        if let last = lastCompactedHour, last < hour {
            try? usageStore.compactHour(last, limit: 20)
            lastCompactedHour = hour
        } else if lastCompactedHour == nil {
            lastCompactedHour = hour
        }
    }

    /// On launch: drop usage older than the retention window and compact any
    /// already-closed hours left untruncated by a previous crash.
    func performUsageLaunchMaintenance() {
        guard let usageStore else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -preferences.usageRetentionDays, to: Date())
            ?? .distantPast
        try? usageStore.prune(olderThan: cutoff)
        let currentHour = UsageBucketing.hourStart(of: Date(), calendar: .current)
        for hour in (try? usageStore.distinctHours(before: currentHour)) ?? [] {
            try? usageStore.compactHour(hour, limit: 20)
        }
    }
}
