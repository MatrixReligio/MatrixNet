/// The identity of the process that owns a connection or packet.
///
/// Populated from the kernel-attributed PID (NetworkStatistics) or per-packet
/// PID (PKTAP), then enriched with bundle/display information by the app layer.
public struct AppIdentity: Hashable, Sendable, Identifiable {
    public let pid: Int32
    public let bundleIdentifier: String?
    public let displayName: String
    public let executablePath: String?

    public var id: Int32 {
        pid
    }

    /// Creates an identity, deriving a human-readable display name when one is
    /// not supplied: the executable's file name if available, otherwise a
    /// `PID <n>` placeholder.
    public init(
        pid: Int32,
        bundleIdentifier: String? = nil,
        displayName: String? = nil,
        executablePath: String? = nil
    ) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.executablePath = executablePath
        self.displayName = Self.resolveDisplayName(displayName, executablePath: executablePath, pid: pid)
    }

    private static func resolveDisplayName(_ provided: String?, executablePath: String?, pid: Int32) -> String {
        if let provided, !provided.isEmpty {
            return provided
        }
        let fileName = executablePath?.split(separator: "/", omittingEmptySubsequences: true).last
        if let fileName, !fileName.isEmpty {
            return String(fileName)
        }
        return "PID \(pid)"
    }

    /// A placeholder identity for traffic that cannot be attributed to a process.
    public static let unknown = AppIdentity(pid: -1, displayName: "Unknown")
}

/// Session-cumulative traffic attributed to one app.
///
/// Unlike a live connection's instantaneous counters — which are 0 for the many
/// idle keep-alive sockets and are lost the moment a short-lived flow closes —
/// this accumulates the positive growth of every connection's counters bucketed
/// by app, and survives connection removal. It is what the Overview and widget
/// "top talkers" should display, so they stay meaningful instead of showing 0.
public struct AppTraffic: Sendable, Equatable, Identifiable {
    public var app: AppIdentity
    public var bytesIn: UInt64
    public var bytesOut: UInt64

    public var id: String {
        app.displayName
    }

    public var bytes: UInt64 {
        bytesIn &+ bytesOut
    }

    public init(app: AppIdentity, bytesIn: UInt64 = 0, bytesOut: UInt64 = 0) {
        self.app = app
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}
