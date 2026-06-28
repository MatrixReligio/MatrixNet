import Foundation
import MatrixNetCapture
import MatrixNetModel
import MatrixNetStore
import Observation
import WidgetKit

/// Top-level observable state for the connection monitor. Bridges the passive,
/// actor-isolated capture pipeline to SwiftUI on the main actor: it drains the
/// `NetworkStatisticsMonitor` event stream into a `ConnectionAggregator` and
/// periodically publishes a sorted snapshot for the views to render.
@MainActor
@Observable
public final class AppModel {
    /// The current connections, sorted for display (most recently active first).
    public private(set) var connections: [Connection] = []
    /// Whether passive monitoring is active.
    public private(set) var isMonitoring = false
    /// Set when the NetworkStatistics framework is unavailable on this system.
    public private(set) var monitoringUnavailable = false

    /// Session-cumulative bytes received since monitoring started (monotonic).
    public private(set) var sessionBytesIn: UInt64 = 0
    /// Session-cumulative bytes sent since monitoring started.
    public private(set) var sessionBytesOut: UInt64 = 0
    /// Current inbound throughput in bytes per second.
    public private(set) var throughputIn: Double = 0
    /// Current outbound throughput in bytes per second.
    public private(set) var throughputOut: Double = 0

    /// Session-cumulative per-app traffic, sorted by total bytes (most first).
    /// The Overview and widget "top talkers" read this rather than summing the
    /// live snapshot's instantaneous per-connection bytes (which are ~0 for the
    /// many idle keep-alive sockets, and lost when short-lived flows close).
    public private(set) var topApps: [AppTraffic] = []

    /// Number of currently active connections whose remote IP is on the threat
    /// list. Surfaced in the app and widget; advisory only (never blocks).
    public private(set) var threatCount: Int = 0

    /// Recent throughput samples (≈ last minute) for the Overview live chart.
    public private(set) var throughputHistory = ThroughputHistory(capacity: 60)
    /// Distinct processes with an active connection.
    public private(set) var activeAppCount: Int = 0
    /// Distinct known destination countries among active connections.
    public private(set) var countriesReached: Int = 0
    /// Fraction (0...1) of active connections routed through a proxy.
    public private(set) var proxyShare: Double = 0
    /// Active-connection share by application protocol (most common first).
    public private(set) var protocolMix: [ProtocolShare] = []
    /// Active connections grouped by destination country (most connections first).
    public private(set) var destinationCountries: [CountryActivity] = []
    /// Countries that currently host at least one threat-flagged active remote.
    public private(set) var threatCountries: Set<String> = []
    /// Known IP→hostname map (reverse DNS + DNS-enriched), keyed by the IP's
    /// string form, for views that only have the textual address (e.g. Packets).
    public private(set) var resolvedHostnames: [String: String] = [:]
    /// The busiest apps, enriched with live connection count, country flag, and
    /// threat/tunnel markers for the Overview "Top Talkers" list.
    private(set) var topTalkers: [TopTalker] = []

    /// Posts threat-connection notifications; set by the app delegate at launch.
    var threatNotifier: ThreatNotifier?
    private let preferences = Preferences(defaults: SharedMetricsStore.sharedDefaults ?? .standard)

    private var monitor: NetworkStatisticsMonitor?
    /// Shared with the packet pipeline so captured packets are attributed to the
    /// same connections (the aggregator is built for both sources).
    let aggregator = ConnectionAggregator()
    private let resolver = HostnameResolver()
    private let historyStore = try? HistoryStore.persistent()
    private let usageStore = try? UsageStore.persistent()
    private var lastUsageSeen: [String: UsageTotals] = [:]
    private var lastUsageFlush = Date.distantPast
    private var lastCompactedHour: Date?
    private var pumpTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var lastMetricsWrite = Date.distantPast
    private var lastWidgetReload = Date.distantPast
    private var lastHistoryWrite = Date.distantPast
    private var lastRateSampleAt = Date.distantPast
    private var lastRateBytesIn: UInt64 = 0
    private var lastRateBytesOut: UInt64 = 0

    public init() {
        performUsageLaunchMaintenance()
    }

    /// The total number of currently active (not closed) connections.
    public var activeCount: Int {
        connections.lazy.count(where: { $0.state == .active })
    }

    /// Aggregate throughput counters across all tracked connections.
    public var totalBytesIn: UInt64 {
        connections.reduce(0) { $0 &+ $1.bytesIn }
    }

    public var totalBytesOut: UInt64 {
        connections.reduce(0) { $0 &+ $1.bytesOut }
    }

    /// Starts passive monitoring. No privileges or user approval required.
    public func start() {
        guard !isMonitoring else { return }
        guard let monitor = NetworkStatisticsMonitor() else {
            monitoringUnavailable = true
            return
        }
        self.monitor = monitor
        isMonitoring = true

        // Clear any state from a previous session before the new stream begins
        // (the monitor reassigns ids on restart, so stale entries would linger).
        sessionBytesIn = 0
        sessionBytesOut = 0
        throughputIn = 0
        throughputOut = 0
        lastRateSampleAt = .distantPast
        lastRateBytesIn = 0
        lastRateBytesOut = 0
        // The aggregator's usage totals are reset alongside the new stream, so
        // the delta baseline must restart from empty too.
        lastUsageSeen.removeAll()
        lastCompactedHour = UsageBucketing.hourStart(of: Date(), calendar: .current)

        let stream = monitor.start()
        let aggregator = aggregator
        let resolver = resolver
        pumpTask = Task {
            await aggregator.reset()
            await aggregator.consume(stream)
        }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot = await aggregator.snapshot()
                let session = await aggregator.sessionTotals()
                let apps = await aggregator.appTraffic()
                await resolver.resolveIfNeeded(snapshot.map(\.fiveTuple.destination.address))
                let hostnames = await resolver.snapshot()
                self?.publish(snapshot, hostnames: hostnames, session: session, apps: apps)
                await self?.flushUsage(now: Date())
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Stops monitoring and tears down the pipeline.
    public func stop() {
        monitor?.stop()
        monitor = nil
        pumpTask?.cancel()
        refreshTask?.cancel()
        pumpTask = nil
        refreshTask = nil
        isMonitoring = false
        throughputIn = 0
        throughputOut = 0
    }

    private func publish(
        _ snapshot: [Connection],
        hostnames: [IPAddress: String],
        session: (bytesIn: UInt64, bytesOut: UInt64),
        apps: [AppTraffic]
    ) {
        topApps = apps.sorted { $0.bytes > $1.bytes }
        // Resolve icons here (off the scroll path); cells then read the cache.
        AppIconResolver.shared.prewarm(snapshot.map(\.app))
        connections = snapshot
            .map { connection in
                guard connection.remoteHostname == nil,
                      let hostname = hostnames[connection.fiveTuple.destination.address]
                else {
                    return connection
                }
                var enriched = connection
                enriched.remoteHostname = hostname
                return enriched
            }
            .sorted { lhs, rhs in
                if (lhs.state == .active) != (rhs.state == .active) {
                    return lhs.state == .active // active connections first
                }
                return lhs.lastActivityAt > rhs.lastActivityAt
            }
        let threats = connections.filter {
            $0.state == .active && Threat.isThreat($0.fiveTuple.destination.address)
        }
        threatCount = threats.count
        threatNotifier?.evaluate(
            threats.map {
                ThreatNotifier.Hit(
                    app: $0.app.displayName,
                    ip: $0.fiveTuple.destination.address.description,
                    host: $0.remoteHostname
                )
            },
            enabled: preferences.threatNotificationsEnabled
        )

        activeAppCount = OverviewStats.activeAppCount(connections)
        countriesReached = OverviewStats.countriesReached(connections) { GeoIP.country(for: $0) }
        proxyShare = OverviewStats.proxyShare(connections) { ProxyInfo.routesThroughProxy($0) }
        protocolMix = OverviewStats.protocolMix(connections)
        destinationCountries = OverviewStats.destinationCountries(connections) { GeoIP.country(for: $0) }
        threatCountries = Set(threats.compactMap { GeoIP.country(for: $0.fiveTuple.destination.address) })
        var nameMap: [String: String] = [:]
        for (ip, name) in hostnames {
            nameMap[ip.description] = name
        }
        for connection in connections {
            if let host = connection.remoteHostname {
                nameMap[connection.fiveTuple.destination.address.description] = host
            }
        }
        resolvedHostnames = nameMap
        topTalkers = makeTopTalkers(connections: connections)

        updateThroughput(session: session)
        publishWidgetMetrics()
        recordHistory()
    }

    /// Builds the enriched "Top Talkers" rows from the busiest apps and their
    /// current active connections (country flag, threat hit, tunnel role).
    private func makeTopTalkers(connections: [Connection]) -> [TopTalker] {
        let activeByApp = Dictionary(grouping: connections.filter { $0.state == .active }, by: \.app)
        return topApps.prefix(8).map { entry in
            let conns = activeByApp[entry.app] ?? []
            let flag = conns.lazy.compactMap { GeoIP.flag(for: $0.fiveTuple.destination.address) }.first
            let isThreat = conns.contains { Threat.isThreat($0.fiveTuple.destination.address) }
            return TopTalker(
                app: entry.app,
                bytes: entry.bytes,
                connectionCount: conns.count,
                flag: flag,
                isThreat: isThreat,
                isTunnel: ProxyInfo.isTunnel(entry.app.displayName)
            )
        }
    }

    /// Updates the session totals and derives the throughput rate from the byte
    /// delta since the last sample. Driven by the ~1s refresh tick.
    private func updateThroughput(session: (bytesIn: UInt64, bytesOut: UInt64)) {
        let now = Date()
        sessionBytesIn = session.bytesIn
        sessionBytesOut = session.bytesOut
        let elapsed = now.timeIntervalSince(lastRateSampleAt)
        if lastRateSampleAt != .distantPast, elapsed > 0.1 {
            let deltaIn = session.bytesIn >= lastRateBytesIn ? session.bytesIn - lastRateBytesIn : 0
            let deltaOut = session.bytesOut >= lastRateBytesOut ? session.bytesOut - lastRateBytesOut : 0
            throughputIn = Double(deltaIn) / elapsed
            throughputOut = Double(deltaOut) / elapsed
        }
        lastRateSampleAt = now
        lastRateBytesIn = session.bytesIn
        lastRateBytesOut = session.bytesOut
        throughputHistory.append(ThroughputSample(time: now, inRate: throughputIn, outRate: throughputOut))
    }

    /// The most recent persisted connection-history records.
    public func recentHistory(limit: Int = 200) -> [ConnectionHistoryRecord] {
        (try? historyStore?.recent(limit: limit)) ?? []
    }

    /// Persists the current connections to history (throttled).
    private func recordHistory() {
        let now = Date()
        guard let historyStore, now.timeIntervalSince(lastHistoryWrite) >= 5 else { return }
        lastHistoryWrite = now

        let summaries = connections.map { connection in
            ConnectionSummary(
                appName: connection.app.displayName,
                remoteHost: connection.remoteHostname ?? connection.fiveTuple.destination.address.description,
                proto: connection.fiveTuple.proto.displayName,
                bytesIn: Int(min(connection.bytesIn, UInt64(Int.max))),
                bytesOut: Int(min(connection.bytesOut, UInt64(Int.max))),
                at: connection.lastActivityAt
            )
        }
        try? historyStore.record(summaries)
    }

    /// Hourly usage rows for the Usage tab over the given reporting period.
    public func usageRows(for period: UsagePeriod) -> [UsageRow] {
        (try? usageStore?.fetch(range: period.range(now: Date(), calendar: .current))) ?? []
    }

    /// Diffs the aggregator's monotonic per-flow usage totals and persists the
    /// positive growth into hourly buckets. Throttled to ≈ 30s, with the prior
    /// hour compacted to its top destinations once it rolls over.
    private func flushUsage(now: Date) async {
        guard let usageStore, now.timeIntervalSince(lastUsageFlush) >= 30 else { return }
        lastUsageFlush = now

        let snapshot = await aggregator.usageSnapshot()
        var current: [String: UsageTotals] = [:]
        var meta: [String: ConnectionAggregator.UsageFlowTotal] = [:]
        for flow in snapshot {
            let key = "\(flow.app)\u{1F}\(flow.address.description)"
            current[key] = UsageTotals(bytesIn: flow.bytesIn, bytesOut: flow.bytesOut)
            meta[key] = flow
        }
        let deltas = UsageAccumulator.deltas(previous: lastUsageSeen, current: current)
        lastUsageSeen = current
        guard !deltas.isEmpty else { return }

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
                    periodStart: hour, app: flow.app, host: host, country: country,
                    bytesIn: delta.bytesIn, bytesOut: delta.bytesOut
                )
            }
        }
        try? usageStore.accumulate(Array(merged.values))

        if let last = lastCompactedHour, last < hour {
            try? usageStore.compactHour(last, n: 20)
            lastCompactedHour = hour
        } else if lastCompactedHour == nil {
            lastCompactedHour = hour
        }
    }

    /// On launch: drop usage older than the retention window and compact any
    /// already-closed hours left untruncated by a previous crash.
    private func performUsageLaunchMaintenance() {
        guard let usageStore else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -preferences.usageRetentionDays, to: Date())
            ?? .distantPast
        try? usageStore.prune(olderThan: cutoff)
        let currentHour = UsageBucketing.hourStart(of: Date(), calendar: .current)
        for hour in (try? usageStore.distinctHours(before: currentHour)) ?? [] {
            try? usageStore.compactHour(hour, n: 20)
        }
    }

    /// Publishes a compact metrics snapshot to the shared App Group container and
    /// asks WidgetKit to reload the widget's timeline. Throttled so the widget
    /// stays fresh without thrashing the disk or the reload budget.
    private func publishWidgetMetrics() {
        let now = Date()
        guard now.timeIntervalSince(lastMetricsWrite) >= 2, let url = SharedMetricsStore.defaultURL() else {
            return
        }
        lastMetricsWrite = now

        let widgetApps = topApps.prefix(5).map { MetricsSnapshot.TopApp(name: $0.app.displayName, bytes: $0.bytes) }

        let snapshot = MetricsSnapshot(
            activeConnections: activeCount,
            totalConnections: connections.count,
            bytesIn: sessionBytesIn,
            bytesOut: sessionBytesOut,
            throughputIn: throughputIn,
            throughputOut: throughputOut,
            topApps: Array(widgetApps),
            threatCount: threatCount,
            updatedAt: now
        )
        guard SharedMetricsStore.write(snapshot, to: url) else { return }
        // The app writes; the widget reads. Nudge WidgetKit to refresh — but
        // sparingly: reloadAllTimelines has a system budget, and calling it every
        // couple of seconds exhausts it so later reloads are silently dropped and
        // the widget appears frozen. ~20s keeps it live without burning the budget
        // (the widget's own timeline policy refreshes it between nudges).
        if now.timeIntervalSince(lastWidgetReload) >= 20 {
            lastWidgetReload = now
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

/// A busiest-app row for the Overview, enriched from the app's live connections.
struct TopTalker: Identifiable {
    let app: AppIdentity
    let bytes: UInt64
    let connectionCount: Int
    let flag: String?
    let isThreat: Bool
    let isTunnel: Bool

    var id: AppIdentity.ID {
        app.id
    }
}
