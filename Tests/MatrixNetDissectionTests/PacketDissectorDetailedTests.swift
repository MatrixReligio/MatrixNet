import MatrixNetModel
import Testing
@testable import MatrixNetDissection

/// Verifies the lightweight (no field-tree) dissection mode used by live capture:
/// `dissect(..., detailed: false)` must produce identical extracted values
/// (five-tuple, summary, protocol path, hostnames, JA4 fingerprint, TCP segment)
/// while every layer carries empty `fields`/`children` but a correct
/// `label`/`shortName`/`byteRange`.
@Suite("PacketDissector – lightweight (no field tree) mode")
struct PacketDissectorDetailedTests {
    private let dissector = PacketDissector()

    /// Ethernet + IPv4(192.168.1.5→93.184.216.34) + TCP(50000→443) + TLS
    /// ClientHello with SNI example.com (exercises JA4). Reused from the JA4 and
    /// hostname suites.
    private let tlsClientHello = """
    aabbccddeeff 112233445566 0800
    45 00 0070 1c46 4000 40 06 0000 c0a80105 5db8d822
    c350 01bb 00000000 00000000 5018 ffff 0000 0000
    16 0301 0043
    01 00003F
    0303 0000000000000000000000000000000000000000000000000000000000000000
    00 0002 1301 01 00
    0014 0000 0010 000E 00 000B 6578616d706c652e636f6d
    """

    /// Ethernet + IPv4(8.8.8.8→192.168.1.5) + UDP(53→49152) + DNS response
    /// answering example.com = 93.184.216.34. Reused from the hostname suite.
    private let dnsResponse = """
    aabbccddeeff 112233445566 0800
    45 00 0049 0001 0000 40 11 0000 08080808 c0a80105
    0035 c000 0035 0000
    1234 8180 0001 0001 0000 0000
    07 6578616d706c65 03 636f6d 00 0001 0001
    C00C 0001 0001 0000012C 0004 5db8d822
    """

    @Test("a TCP+TLS ClientHello dissects identically with and without the field tree")
    func tlsClientHelloEquivalence() {
        assertLightweightMatchesDetailed(hex(tlsClientHello))
    }

    @Test("a DNS response dissects identically with and without the field tree")
    func dnsResponseEquivalence() {
        assertLightweightMatchesDetailed(hex(dnsResponse))
    }

    /// Asserts the two modes agree on every extracted value, then that the
    /// lightweight layers are field/children-free while still naming themselves.
    private func assertLightweightMatchesDetailed(_ bytes: [UInt8]) {
        let detailed = dissector.dissect(bytes, linkType: .ethernet, detailed: true)
        let light = dissector.dissect(bytes, linkType: .ethernet, detailed: false)

        // Extracted values must be byte-for-byte identical across modes.
        #expect(light.fiveTuple == detailed.fiveTuple)
        #expect(light.summary == detailed.summary)
        #expect(light.protocolPath == detailed.protocolPath)
        #expect(light.hostnames == detailed.hostnames)
        #expect(light.tlsClientFingerprint == detailed.tlsClientFingerprint)
        #expect(light.tcpSegment == detailed.tcpSegment)

        // Only the per-layer display data differs: empty in lightweight mode, but
        // the layer is still present, named, and byte-ranged identically.
        #expect(light.layers.count == detailed.layers.count)
        for (lightLayer, detailedLayer) in zip(light.layers, detailed.layers) {
            #expect(lightLayer.fields.isEmpty)
            #expect(lightLayer.children.isEmpty)
            #expect(!lightLayer.shortName.isEmpty)
            #expect(!lightLayer.label.isEmpty)
            #expect(lightLayer.shortName == detailedLayer.shortName)
            #expect(lightLayer.label == detailedLayer.label)
            #expect(lightLayer.byteRange == detailedLayer.byteRange)
        }
    }
}
