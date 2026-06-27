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

    private var monitor: NetworkStatisticsMonitor?
    /// Shared with the packet pipeline so captured packets are attributed to the
    /// same connections (the aggregator is built for both sources).
    let aggregator = ConnectionAggregator()
    private let resolver = HostnameResolver()
    private let historyStore = try? HistoryStore.persistent()
    private var pumpTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var lastMetricsWrite = Date.distantPast
    private var lastWidgetReload = Date.distantPast
    private var lastHistoryWrite = Date.distantPast
    private var lastRateSampleAt = Date.distantPast
    private var lastRateBytesIn: UInt64 = 0
    private var lastRateBytesOut: UInt64 = 0

    public init() {}

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
        threatCount = connections.lazy
            .count(where: { $0.state == .active && Threat.isThreat($0.fiveTuple.destination.address) })

        updateThroughput(session: session)
        publishWidgetMetrics()
        recordHistory()
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
