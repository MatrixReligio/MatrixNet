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

    public let activeConnections: Int
    public let bytesIn: UInt64
    public let bytesOut: UInt64
    public let topApps: [TopApp]
    public let updatedAt: Date

    public init(
        activeConnections: Int,
        bytesIn: UInt64,
        bytesOut: UInt64,
        topApps: [TopApp],
        updatedAt: Date
    ) {
        self.activeConnections = activeConnections
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.topApps = topApps
        self.updatedAt = updatedAt
    }

    public static let empty = MetricsSnapshot(
        activeConnections: 0, bytesIn: 0, bytesOut: 0, topApps: [], updatedAt: .distantPast
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
