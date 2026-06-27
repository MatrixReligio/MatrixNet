import Foundation

/// One throughput reading: the inbound and outbound byte rates at a point in time.
public struct ThroughputSample: Equatable, Sendable {
    public let time: Date
    public let inRate: Double
    public let outRate: Double

    public init(time: Date, inRate: Double, outRate: Double) {
        self.time = time
        self.inRate = inRate
        self.outRate = outRate
    }
}

/// A fixed-capacity ring of recent throughput samples for the live Overview
/// chart. Appending past capacity evicts the oldest sample, so it always holds
/// the most recent `capacity` readings (≈ the last minute at 1 Hz).
public struct ThroughputHistory: Sendable {
    public let capacity: Int
    private var storage: [ThroughputSample] = []

    public init(capacity: Int = 60) {
        self.capacity = max(1, capacity)
    }

    public mutating func append(_ sample: ThroughputSample) {
        storage.append(sample)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }

    /// The samples, oldest first.
    public var values: [ThroughputSample] {
        storage
    }

    /// The largest in/out rate across the window (for charting a headroom axis).
    public var peakRate: Double {
        storage.reduce(0) { max($0, max($1.inRate, $1.outRate)) }
    }
}
