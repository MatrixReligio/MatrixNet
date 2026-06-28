import Foundation
import MatrixNetModel

/// Raised by a layer dissector when the bytes cannot form a valid header.
/// The orchestrator catches these and produces a partial dissection.
enum DissectionError: Error {
    case malformed
}

/// Intermediate result of dissecting a network (IP) layer.
struct NetworkLayerResult {
    let node: DissectionNode
    /// IANA IP protocol number of the payload.
    let ipProtocol: UInt8
    /// Absolute offset where the transport layer begins.
    let payloadOffset: Int
    /// Absolute offset where the IP datagram's payload ends (from the IP length
    /// field, clamped to the buffer), so a transport layer can size its payload
    /// without trusting the captured buffer length (which may include link-layer
    /// padding).
    let payloadEnd: Int
    let source: IPAddress
    let destination: IPAddress
}

/// Intermediate result of dissecting a transport layer.
struct TransportLayerResult {
    let node: DissectionNode
    let sourcePort: UInt16
    let destinationPort: UInt16
    /// Absolute offset where the application payload begins.
    let payloadOffset: Int
    /// The structured TCP fields, when the transport is TCP (nil for UDP).
    let tcpSegment: TCPSegment?
}

enum HexFormat {
    /// Formats bytes as a colon-separated MAC address (lowercase).
    static func mac(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    static func hex16(_ value: UInt16) -> String {
        String(format: "0x%04x", value)
    }
}
