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

    private var monitor: NetworkStatisticsMonitor?
    private let aggregator = ConnectionAggregator()
    private let resolver = HostnameResolver()
    private let historyStore = try? HistoryStore.persistent()
    private var pumpTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var lastMetricsWrite = Date.distantPast
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

        let stream = monitor.start()
        let aggregator = aggregator
        let resolver = resolver
        pumpTask = Task { await aggregator.consume(stream) }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot = await aggregator.snapshot()
                let session = await aggregator.sessionTotals()
                await resolver.resolveIfNeeded(snapshot.map(\.fiveTuple.destination.address))
                let hostnames = await resolver.snapshot()
                self?.publish(snapshot, hostnames: hostnames, session: session)
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

    private func publish(_ snapshot: [Connection], hostnames: [IPAddress: String], session: (bytesIn: UInt64, bytesOut: UInt64)) {
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

        let topApps = Dictionary(grouping: connections, by: \.app.displayName)
            .map { name, group in MetricsSnapshot.TopApp(name: name, bytes: group.reduce(0) { $0 &+ $1.totalBytes }) }
            .sorted { $0.bytes > $1.bytes }
            .prefix(5)

        let snapshot = MetricsSnapshot(
            activeConnections: activeCount,
            totalConnections: connections.count,
            bytesIn: sessionBytesIn,
            bytesOut: sessionBytesOut,
            throughputIn: throughputIn,
            throughputOut: throughputOut,
            topApps: Array(topApps),
            updatedAt: now
        )
        guard SharedMetricsStore.write(snapshot, to: url) else { return }
        // The app writes; the widget reads. Without this nudge the widget would
        // only refresh on its own (slow) timeline policy and appear frozen.
        WidgetCenter.shared.reloadAllTimelines()
    }
}
