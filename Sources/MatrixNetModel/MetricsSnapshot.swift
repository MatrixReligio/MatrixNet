import Foundation

/// A compact snapshot of live metrics the app publishes for the desktop widget
/// (and any other read-only consumer) via a shared App Group container.
public struct MetricsSnapshot: Codable, Sendable, Equatable {
    public struct TopApp: Codable, Sendable, Equatable {
        public let name: String
        public let bytes: UInt64
        public init(name: String, bytes: UInt64) {
            self.name = name
            self.bytes = bytes
        }
    }

    /// Number of currently active (not closed) connections.
    public let activeConnections: Int
    /// Total tracked connections (active plus recently closed in the snapshot).
    public let totalConnections: Int
    /// Session-cumulative bytes received (monotonic; survives connection close).
    public let bytesIn: UInt64
    /// Session-cumulative bytes sent.
    public let bytesOut: UInt64
    /// Current inbound throughput in bytes per second.
    public let throughputIn: Double
    /// Current outbound throughput in bytes per second.
    public let throughputOut: Double
    public let topApps: [TopApp]
    public let updatedAt: Date

    public init(
        activeConnections: Int,
        totalConnections: Int = 0,
        bytesIn: UInt64,
        bytesOut: UInt64,
        throughputIn: Double = 0,
        throughputOut: Double = 0,
        topApps: [TopApp],
        updatedAt: Date
    ) {
        self.activeConnections = activeConnections
        self.totalConnections = totalConnections
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.throughputIn = throughputIn
        self.throughputOut = throughputOut
        self.topApps = topApps
        self.updatedAt = updatedAt
    }

    /// Tolerant decoding: snapshots written by an older app version omit the
    /// newer fields, so default them rather than failing the whole read.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeConnections = try container.decode(Int.self, forKey: .activeConnections)
        totalConnections = try container.decodeIfPresent(Int.self, forKey: .totalConnections) ?? 0
        bytesIn = try container.decode(UInt64.self, forKey: .bytesIn)
        bytesOut = try container.decode(UInt64.self, forKey: .bytesOut)
        throughputIn = try container.decodeIfPresent(Double.self, forKey: .throughputIn) ?? 0
        throughputOut = try container.decodeIfPresent(Double.self, forKey: .throughputOut) ?? 0
        topApps = try container.decodeIfPresent([TopApp].self, forKey: .topApps) ?? []
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    public static let empty = MetricsSnapshot(
        activeConnections: 0,
        totalConnections: 0,
        bytesIn: 0,
        bytesOut: 0,
        throughputIn: 0,
        throughputOut: 0,
        topApps: [],
        updatedAt: .distantPast
    )
}

/// Reads/writes a `MetricsSnapshot` as JSON. The app writes; the widget reads.
/// File access is injectable for testing; the default location is the shared
/// App Group container so the sandboxed widget extension can read it.
public enum SharedMetricsStore {
    public static let appGroupIdentifier = "group.com.matrixreligio.matrixnet"
    public static let fileName = "metrics.json"

    /// Default shared-container URL, or `nil` if the App Group is unavailable.
    public static func defaultURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(fileName)
    }

    @discardableResult
    public static func write(_ snapshot: MetricsSnapshot, to url: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    public static func read(from url: URL) -> MetricsSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MetricsSnapshot.self, from: data)
    }
}
