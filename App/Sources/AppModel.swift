import Foundation
import MatrixNetCapture
import MatrixNetModel
import Observation

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

    private var monitor: NetworkStatisticsMonitor?
    private let aggregator = ConnectionAggregator()
    private let resolver = HostnameResolver()
    private var pumpTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

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
                await resolver.resolveIfNeeded(snapshot.map(\.fiveTuple.destination.address))
                let hostnames = await resolver.snapshot()
                self?.publish(snapshot, hostnames: hostnames)
                try? await Task.sleep(for: .milliseconds(700))
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
    }

    private func publish(_ snapshot: [Connection], hostnames: [IPAddress: String]) {
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
    }
}
