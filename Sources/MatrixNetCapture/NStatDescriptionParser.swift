import Foundation
import MatrixNetModel

/// Translates a NetworkStatistics "description" dictionary (as delivered by
/// `NStatSourceSetDescriptionBlock`) into a domain `Connection`.
///
/// The dictionary keys are those observed on macOS (see
/// `docs/superpowers/notes/capture-spike.md`): `provider`, `localAddress`,
/// `remoteAddress`, `processID`, `processName`, `rxBytes`, `txBytes`.
enum NStatDescriptionParser {
    /// Builds a `Connection` from a description dictionary, or `nil` if the
    /// essential fields (protocol + both endpoints) are missing or malformed.
    static func connection(from description: [String: Any], id: UUID, startedAt: Date) -> Connection? {
        guard let provider = description["provider"] as? String,
              let proto = transportProtocol(from: provider),
              let localData = description["localAddress"] as? Data,
              let remoteData = description["remoteAddress"] as? Data,
              let source = SocketAddress.endpoint(fromSockaddr: [UInt8](localData)),
              let destination = SocketAddress.endpoint(fromSockaddr: [UInt8](remoteData))
        else {
            return nil
        }

        let pid = Int32(truncatingIfNeeded: intValue(description["processID"]) ?? -1)
        let name = description["processName"] as? String
        let bytesIn = uint64Value(description["rxBytes"])
        let bytesOut = uint64Value(description["txBytes"])
        let packetsIn = uint64Value(description["rxPackets"])
        let packetsOut = uint64Value(description["txPackets"])

        // Skip idle listening sockets and half-open entries: a remote port of 0
        // means no real peer. Connected-UDP and receiving sockets (mDNS, QUIC,
        // multicast) also report remote port 0 but DO carry traffic, so keep a
        // port-0 source whenever it has observed bytes — otherwise its traffic
        // would never reach the byte counters or the session totals.
        guard destination.port != 0 || bytesIn > 0 || bytesOut > 0 else { return nil }

        return Connection(
            id: id,
            fiveTuple: FiveTuple(proto: proto, source: source, destination: destination),
            app: AppIdentity(pid: pid, displayName: name),
            bytesOut: bytesOut,
            bytesIn: bytesIn,
            packetsOut: packetsOut,
            packetsIn: packetsIn,
            startedAt: startedAt,
            state: connectionState(from: description, proto: proto)
        )
    }

    /// Maps NetworkStatistics' `TCPState` to our active/closed state. UDP and
    /// other protocols have no TCP state, so a present flow is considered active.
    static func connectionState(from description: [String: Any], proto: TransportProtocol) -> ConnectionState {
        guard proto == .tcp, let tcpState = description["TCPState"] as? String else { return .active }
        switch tcpState {
        case "Closed", "TimeWait", "CloseWait", "LastAck", "Closing", "FinWait1", "FinWait2":
            return .closed
        default:
            return .active
        }
    }

    /// Builds a counter snapshot from a NetworkStatistics counts dictionary.
    static func counts(from dictionary: [String: Any], at timestamp: Date) -> ConnectionCounts {
        ConnectionCounts(
            bytesIn: uint64Value(dictionary["rxBytes"]),
            bytesOut: uint64Value(dictionary["txBytes"]),
            packetsIn: uint64Value(dictionary["rxPackets"]),
            packetsOut: uint64Value(dictionary["txPackets"]),
            timestamp: timestamp
        )
    }

    /// Extracts the transport protocol from the `provider` field.
    static func transportProtocol(from provider: String) -> TransportProtocol? {
        switch provider.uppercased() {
        case "TCP": .tcp
        case "UDP": .udp
        default: nil
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let intValue = value as? Int { return intValue }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private static func uint64Value(_ value: Any?) -> UInt64 {
        guard let intValue = intValue(value), intValue >= 0 else { return 0 }
        return UInt64(intValue)
    }
}
