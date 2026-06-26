/// The identity of the process that owns a connection or packet.
///
/// Populated from the kernel-attributed PID (NetworkStatistics) or per-packet
/// PID (PKTAP), then enriched with bundle/display information by the app layer.
public struct AppIdentity: Hashable, Sendable, Identifiable {
    public let pid: Int32
    public let bundleIdentifier: String?
    public let displayName: String
    public let executablePath: String?

    public var id: Int32 { pid }

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
        if let path = executablePath,
           let component = path.split(separator: "/", omittingEmptySubsequences: true).last,
           !component.isEmpty {
            return String(component)
        }
        return "PID \(pid)"
    }

    /// A placeholder identity for traffic that cannot be attributed to a process.
    public static let unknown = AppIdentity(pid: -1, displayName: "Unknown")
}
