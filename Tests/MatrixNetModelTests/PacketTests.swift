import Foundation
import Testing
@testable import MatrixNetModel

@Suite("Packet")
struct PacketTests {
    private func makePacket(captured: Int, original: Int) -> Packet {
        Packet(
            id: 1,
            timestamp: Date(timeIntervalSince1970: 0),
            direction: .outbound,
            pid: nil,
            originalLength: original,
            data: [UInt8](repeating: 0, count: captured),
            interfaceName: "en0"
        )
    }

    @Test("is truncated when captured bytes are shorter than the wire length")
    func truncated() {
        #expect(makePacket(captured: 96, original: 1500).isTruncated)
    }

    @Test("is not truncated when the full packet was captured")
    func notTruncated() {
        #expect(!makePacket(captured: 1500, original: 1500).isTruncated)
    }

    @Test("is not truncated for an empty packet")
    func emptyNotTruncated() {
        #expect(!makePacket(captured: 0, original: 0).isTruncated)
    }

    @Test("captured data longer than the wire length is not reported as truncated")
    func overlongIsNotTruncated() {
        // Documents the boundary: isTruncated only flags captured < original.
        #expect(!makePacket(captured: 100, original: 80).isTruncated)
    }
}
