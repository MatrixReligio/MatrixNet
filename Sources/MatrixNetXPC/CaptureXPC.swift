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

/// Encodes/decodes a batch of `WirePacket`s for one XPC message using a compact,
/// length-prefixed little-endian binary framing.
///
/// This is a hot path: at high packet rates the app decodes a batch many times a
/// second, on every packet, even in the background. The previous `Codable` +
/// binary-property-list approach spent the bulk of the app's capture CPU in
/// `PropertyListDecoder`/`KeyedDecodingContainer` reflection. This hand-rolled
/// codec walks the bytes directly — no reflection, no plist parsing — and is
/// several times cheaper to decode. Decoding is total: any malformed or truncated
/// input yields an empty batch rather than throwing (matching the old `try?`).
///
/// Layout: `UInt32 count`, then per packet — `Float64 timestamp`, `Int32 pid`,
/// `UInt8 direction`, `UInt32 dlt`, `UInt32 originalLength`,
/// `UInt32 nameLength` + UTF-8 name, `UInt32 dataLength` + raw bytes.
/// Helper and app always ship together in one build, so the framing needs no
/// version negotiation (a stale helper is re-registered on update regardless).
public enum WirePacketBatch {
    public static func encode(_ packets: [WirePacket]) -> Data {
        var out = Data()
        out.reserveCapacity(packets.reduce(8) { $0 + 30 + $1.processName.utf8.count + $1.data.count })
        appendU32(UInt32(truncatingIfNeeded: packets.count), to: &out)
        for packet in packets {
            appendU64(packet.timestamp.bitPattern, to: &out)
            appendU32(UInt32(bitPattern: packet.pid), to: &out)
            out.append(packet.direction)
            appendU32(packet.dlt, to: &out)
            appendU32(UInt32(truncatingIfNeeded: packet.originalLength), to: &out)
            let name = Array(packet.processName.utf8)
            appendU32(UInt32(name.count), to: &out)
            out.append(contentsOf: name)
            appendU32(UInt32(packet.data.count), to: &out)
            out.append(packet.data)
        }
        return out
    }

    public static func decode(_ data: Data) -> [WirePacket] {
        let bytes = [UInt8](data)
        var cursor = 0

        func remaining(_ length: Int) -> Bool {
            length >= 0 && cursor + length <= bytes.count
        }
        func readU32() -> UInt32? {
            guard remaining(4) else { return nil }
            defer { cursor += 4 }
            return UInt32(bytes[cursor]) | UInt32(bytes[cursor + 1]) << 8
                | UInt32(bytes[cursor + 2]) << 16 | UInt32(bytes[cursor + 3]) << 24
        }
        func readU64() -> UInt64? {
            guard remaining(8) else { return nil }
            defer { cursor += 8 }
            var value: UInt64 = 0
            for index in 0 ..< 8 {
                value |= UInt64(bytes[cursor + index]) << (8 * index)
            }
            return value
        }

        guard let count = readU32() else { return [] }
        var packets = [WirePacket]()
        packets.reserveCapacity(min(Int(count), bytes.count / 30 + 1))
        for _ in 0 ..< count {
            guard let timestamp = readU64(), let pid = readU32(), remaining(1) else { return [] }
            let direction = bytes[cursor]
            cursor += 1
            guard let dlt = readU32(), let originalLength = readU32(),
                  let nameLength = readU32(), remaining(Int(nameLength)) else { return [] }
            let name = String(bytes: bytes[cursor ..< cursor + Int(nameLength)], encoding: .utf8) ?? ""
            cursor += Int(nameLength)
            guard let dataLength = readU32(), remaining(Int(dataLength)) else { return [] }
            let payload = Data(bytes[cursor ..< cursor + Int(dataLength)])
            cursor += Int(dataLength)
            packets.append(WirePacket(
                timestamp: Double(bitPattern: timestamp),
                pid: Int32(bitPattern: pid),
                processName: name,
                direction: direction,
                dlt: dlt,
                originalLength: Int(originalLength),
                data: payload
            ))
        }
        return packets
    }

    private static func appendU32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private static func appendU64(_ value: UInt64, to data: inout Data) {
        var remaining = value
        for _ in 0 ..< 8 {
            data.append(UInt8(remaining & 0xFF))
            remaining >>= 8
        }
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
