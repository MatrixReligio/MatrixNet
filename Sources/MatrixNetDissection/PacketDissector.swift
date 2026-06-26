import MatrixNetModel

/// Dissects raw captured packets into a layered protocol tree.
///
/// The dissector is deliberately total: any malformed or truncated input yields
/// a best-effort partial dissection rather than throwing or crashing. All reads
/// go through `ByteReader`, which is bounds-checked, and each layer is attempted
/// with `try?` so a failure simply stops the chain.
public struct PacketDissector: Sendable {
    public init() {}

    /// Dissects `bytes` framed according to `linkType`.
    public func dissect(_ bytes: [UInt8], linkType: LinkLayerType) -> DissectedPacket {
        var layers = [DissectionNode]()

        guard let (etherType, networkOffset) = parseLinkLayer(bytes, linkType: linkType, into: &layers) else {
            return DissectedPacket(layers: layers, fiveTuple: nil, summary: summarize(layers, fiveTuple: nil))
        }

        guard let network = parseNetworkLayer(bytes, etherType: etherType, at: networkOffset) else {
            return DissectedPacket(layers: layers, fiveTuple: nil, summary: summarize(layers, fiveTuple: nil))
        }
        layers.append(network.node)

        let proto = TransportProtocol(ipProtocolNumber: network.ipProtocol)
        guard let transport = parseTransportLayer(bytes, proto: proto, at: network.payloadOffset) else {
            return DissectedPacket(layers: layers, fiveTuple: nil, summary: summarize(layers, fiveTuple: nil))
        }
        layers.append(transport.node)

        let fiveTuple = FiveTuple(
            proto: proto,
            source: Endpoint(address: network.source, port: transport.sourcePort),
            destination: Endpoint(address: network.destination, port: transport.destinationPort)
        )

        if let application = parseApplicationLayer(
            bytes,
            ports: (transport.sourcePort, transport.destinationPort),
            at: transport.payloadOffset
        ) {
            layers.append(application)
        }

        return DissectedPacket(layers: layers, fiveTuple: fiveTuple, summary: summarize(layers, fiveTuple: fiveTuple))
    }

    /// Best-effort application-layer dissection, chosen by well-known port. Any
    /// failure simply omits the application layer (never throws).
    private func parseApplicationLayer(
        _ bytes: [UInt8],
        ports: (source: UInt16, destination: UInt16),
        at offset: Int
    ) -> DissectionNode? {
        guard offset < bytes.count else { return nil }
        if ports.source == 53 || ports.destination == 53 {
            return (try? DNSDissector.dissect(bytes, at: offset))?.node
        }
        if ports.source == 443 || ports.destination == 443 || TLSDissector.looksLikeTLS(bytes, at: offset) {
            return (try? TLSDissector.dissect(bytes, at: offset))?.node
        }
        if ports.source == 80 || ports.destination == 80 || HTTPDissector.looksLikeHTTP(bytes, at: offset) {
            return try? HTTPDissector.dissect(bytes, at: offset)
        }
        return nil
    }

    /// Returns the ethertype identifying the network layer and the offset where
    /// it begins, appending the link-layer node when one exists.
    private func parseLinkLayer(
        _ bytes: [UInt8],
        linkType: LinkLayerType,
        into layers: inout [DissectionNode]
    ) -> (etherType: UInt16, offset: Int)? {
        switch linkType {
        case .ethernet:
            guard let ethernet = try? EthernetDissector.dissect(bytes) else { return nil }
            layers.append(ethernet.node)
            return (ethernet.etherType, ethernet.payloadOffset)
        case .rawIP:
            guard let etherType = ipEtherType(forVersionAt: 0, in: bytes) else { return nil }
            return (etherType, 0)
        case .nullLoopback:
            // DLT_NULL: a 4-byte host-order address family precedes the IP header.
            guard bytes.count >= 4, let etherType = ipEtherType(forVersionAt: 4, in: bytes) else { return nil }
            return (etherType, 4)
        }
    }

    private func parseNetworkLayer(_ bytes: [UInt8], etherType: UInt16, at offset: Int) -> NetworkLayerResult? {
        switch etherType {
        case 0x0800: try? IPv4Dissector.dissect(bytes, at: offset)
        case 0x86DD: try? IPv6Dissector.dissect(bytes, at: offset)
        default: nil
        }
    }

    private func parseTransportLayer(
        _ bytes: [UInt8],
        proto: TransportProtocol,
        at offset: Int
    ) -> TransportLayerResult? {
        switch proto {
        case .tcp: try? TCPDissector.dissect(bytes, at: offset)
        case .udp: try? UDPDissector.dissect(bytes, at: offset)
        default: nil
        }
    }

    /// Derives the ethertype from the IP version nibble at `offset`.
    private func ipEtherType(forVersionAt offset: Int, in bytes: [UInt8]) -> UInt16? {
        guard offset < bytes.count else { return nil }
        switch bytes[offset] >> 4 {
        case 4: return 0x0800
        case 6: return 0x86DD
        default: return nil
        }
    }

    private func summarize(_ layers: [DissectionNode], fiveTuple: FiveTuple?) -> String {
        guard let fiveTuple else {
            return layers.last?.shortName ?? "Unknown"
        }
        let proto = layers.last?.shortName ?? fiveTuple.proto.displayName
        let source = "\(fiveTuple.source.address):\(fiveTuple.source.port)"
        let destination = "\(fiveTuple.destination.address):\(fiveTuple.destination.port)"
        return "\(proto) \(source) → \(destination)"
    }
}
