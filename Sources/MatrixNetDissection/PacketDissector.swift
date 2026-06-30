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
    ///
    /// When `detailed` is false the per-layer display field trees are skipped
    /// (each node carries empty `fields`/`children` but a correct
    /// `label`/`shortName`/`byteRange`). All extracted values — the five-tuple,
    /// summary, protocol path, hostnames, JA4 fingerprint, and TCP segment — are
    /// computed identically in both modes; only the inspector display data is
    /// elided. This is the fast path for live capture, where the field tree is
    /// only needed once a user selects a packet.
    public func dissect(_ bytes: [UInt8], linkType: LinkLayerType, detailed: Bool = true) -> DissectedPacket {
        var layers = [DissectionNode]()

        guard let (etherType, networkOffset) = parseLinkLayer(
            bytes,
            linkType: linkType,
            into: &layers,
            detailed: detailed
        ) else {
            return DissectedPacket(layers: layers, fiveTuple: nil, summary: summarize(layers, fiveTuple: nil))
        }

        guard let network = parseNetworkLayer(bytes, etherType: etherType, at: networkOffset, detailed: detailed) else {
            return DissectedPacket(layers: layers, fiveTuple: nil, summary: summarize(layers, fiveTuple: nil))
        }
        layers.append(network.node)

        let proto = TransportProtocol(ipProtocolNumber: network.ipProtocol)
        guard let transport = parseTransportLayer(
            bytes,
            proto: proto,
            at: network.payloadOffset,
            segmentEnd: network.payloadEnd,
            detailed: detailed
        ) else {
            return DissectedPacket(layers: layers, fiveTuple: nil, summary: summarize(layers, fiveTuple: nil))
        }
        layers.append(transport.node)

        let fiveTuple = FiveTuple(
            proto: proto,
            source: Endpoint(address: network.source, port: transport.sourcePort),
            destination: Endpoint(address: network.destination, port: transport.destinationPort)
        )

        var hostnames = [HostnameObservation]()
        var tlsClientFingerprint: String?
        if let application = parseApplicationLayer(
            bytes,
            proto: proto,
            transport: transport,
            destination: network.destination,
            detailed: detailed
        ) {
            layers.append(application.node)
            hostnames = application.hostnames
            tlsClientFingerprint = application.fingerprint
        }

        return DissectedPacket(
            layers: layers,
            fiveTuple: fiveTuple,
            summary: summarize(layers, fiveTuple: fiveTuple),
            hostnames: hostnames,
            tlsClientFingerprint: tlsClientFingerprint,
            tcpSegment: transport.tcpSegment
        )
    }

    /// Best-effort application-layer dissection, chosen by well-known port. Any
    /// failure simply omits the application layer (never throws). Also returns any
    /// hostnames observed: DNS answers (answer IP → queried name) and a TLS
    /// ClientHello's SNI (destination IP → server name).
    /// The application-layer dissection: its node, any hostnames observed, and a
    /// JA4 client fingerprint when the payload is a TLS ClientHello.
    private struct ApplicationLayer {
        let node: DissectionNode
        let hostnames: [HostnameObservation]
        let fingerprint: String?
    }

    private func parseApplicationLayer(
        _ bytes: [UInt8],
        proto: TransportProtocol,
        transport: TransportLayerResult,
        destination: IPAddress,
        detailed: Bool
    ) -> ApplicationLayer? {
        let offset = transport.payloadOffset
        let ports = (source: transport.sourcePort, destination: transport.destinationPort)
        guard offset < bytes.count else { return nil }
        if ports.source == 53 || ports.destination == 53 {
            guard let dns = try? DNSDissector.dissect(bytes, at: offset, detailed: detailed) else { return nil }
            // Bind resolved IPs to the *queried* name, not an answer's canonical
            // name — CDN domains resolve through a CNAME (www.foo.com → foo.cdn.net),
            // and the user-facing host is what was asked for.
            let queriedName = dns.message.questions.first.flatMap { HostnameNormalizer.normalize($0.name) }
            let hostnames = dns.message.answers.compactMap { answer -> HostnameObservation? in
                guard let ip = answer.ip else { return nil }
                guard let name = queriedName ?? HostnameNormalizer.normalize(answer.name) else { return nil }
                return HostnameObservation(ip: ip, name: name)
            }
            return ApplicationLayer(node: dns.node, hostnames: hostnames, fingerprint: nil)
        }
        // QUIC runs over UDP (HTTP/3 on :443). Try it before the TLS branch so a
        // UDP/443 datagram is not mis-dissected as a TLS record.
        if proto == .udp, ports.source == 443 || ports.destination == 443 {
            guard let quic = QUICDissector.dissect(bytes, at: offset, detailed: detailed) else { return nil }
            let hostnames = (quic.serverName.flatMap(HostnameNormalizer.normalize))
                .map { [HostnameObservation(ip: destination, name: $0)] } ?? []
            return ApplicationLayer(node: quic.node, hostnames: hostnames, fingerprint: quic.clientFingerprint)
        }
        if proto == .tcp, ports.source == 443 || ports.destination == 443 || TLSDissector.looksLikeTLS(
            bytes,
            at: offset
        ) {
            guard let tls = try? TLSDissector.dissect(bytes, at: offset, detailed: detailed) else { return nil }
            let hostnames = (tls.serverName.flatMap(HostnameNormalizer.normalize))
                .map { [HostnameObservation(ip: destination, name: $0)] } ?? []
            return ApplicationLayer(node: tls.node, hostnames: hostnames, fingerprint: tls.clientFingerprint)
        }
        if ports.source == 80 || ports.destination == 80 || HTTPDissector.looksLikeHTTP(bytes, at: offset) {
            guard let node = try? HTTPDissector.dissect(bytes, at: offset, detailed: detailed) else { return nil }
            return ApplicationLayer(node: node, hostnames: [], fingerprint: nil)
        }
        return nil
    }

    /// Returns the ethertype identifying the network layer and the offset where
    /// it begins, appending the link-layer node when one exists.
    private func parseLinkLayer(
        _ bytes: [UInt8],
        linkType: LinkLayerType,
        into layers: inout [DissectionNode],
        detailed: Bool
    ) -> (etherType: UInt16, offset: Int)? {
        switch linkType {
        case .ethernet:
            guard let ethernet = try? EthernetDissector.dissect(bytes, detailed: detailed) else { return nil }
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

    private func parseNetworkLayer(
        _ bytes: [UInt8],
        etherType: UInt16,
        at offset: Int,
        detailed: Bool
    ) -> NetworkLayerResult? {
        switch etherType {
        case 0x0800: try? IPv4Dissector.dissect(bytes, at: offset, detailed: detailed)
        case 0x86DD: try? IPv6Dissector.dissect(bytes, at: offset, detailed: detailed)
        default: nil
        }
    }

    private func parseTransportLayer(
        _ bytes: [UInt8],
        proto: TransportProtocol,
        at offset: Int,
        segmentEnd: Int,
        detailed: Bool
    ) -> TransportLayerResult? {
        switch proto {
        case .tcp: try? TCPDissector.dissect(bytes, at: offset, segmentEnd: segmentEnd, detailed: detailed)
        case .udp: try? UDPDissector.dissect(bytes, at: offset, detailed: detailed)
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
