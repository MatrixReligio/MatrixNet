import Foundation

/// The Mach service name the privileged capture helper vends and the app
/// connects to.
public enum CaptureXPC {
    public static let machServiceName = "com.matrixreligio.matrixnet.helper"
    /// The helper's SMAppService daemon plist name.
    public static let helperPlistName = "com.matrixreligio.matrixnet.helper.plist"
}

/// One captured packet on the wire between helper and app. `Codable` so a batch
/// can be encoded to `Data` for a single XPC message (one message per batch keeps
/// the IPC rate low at high packet rates).
public struct WirePacket: Codable, Sendable, Equatable {
    public let timestamp: Double
    public let pid: Int32
    public let processName: String
    /// 0 = unknown, 1 = outbound, 2 = inbound.
    public let direction: UInt8
    /// DLT of `data` (1 = Ethernet, 12 = raw IP).
    public let dlt: UInt32
    public let originalLength: Int
    public let data: Data

    public init(
        timestamp: Double,
        pid: Int32,
        processName: String,
        direction: UInt8,
        dlt: UInt32,
        originalLength: Int,
        data: Data
    ) {
        self.timestamp = timestamp
        self.pid = pid
        self.processName = processName
        self.direction = direction
        self.dlt = dlt
        self.originalLength = originalLength
        self.data = data
    }
}

/// Encodes/decodes a batch of `WirePacket`s for one XPC message.
public enum WirePacketBatch {
    public static func encode(_ packets: [WirePacket]) -> Data {
        (try? JSONEncoder().encode(packets)) ?? Data()
    }

    public static func decode(_ data: Data) -> [WirePacket] {
        (try? JSONDecoder().decode([WirePacket].self, from: data)) ?? []
    }
}

/// Implemented by the helper; called by the app to control capture.
@objc public protocol CaptureControl {
    /// Starts PKTAP capture with an optional BPF filter expression.
    func startCapture(bpfFilter: String?, withReply reply: @escaping (Bool, String?) -> Void)
    /// Stops capture.
    func stopCapture()
    /// Liveness/handshake check returning the helper's version.
    func handshake(withReply reply: @escaping (String) -> Void)
}

/// Implemented by the app; called by the helper to deliver captured packets.
@objc public protocol CaptureClient {
    func didCapture(_ batch: Data)
}
