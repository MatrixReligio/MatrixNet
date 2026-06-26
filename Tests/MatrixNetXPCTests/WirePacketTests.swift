import Foundation
import Testing
@testable import MatrixNetXPC

@Suite("WirePacket batch")
struct WirePacketTests {
    private let packets = [
        WirePacket(
            timestamp: 1_700_000_000.5,
            pid: 501,
            processName: "curl",
            direction: 1,
            dlt: 1,
            originalLength: 1500,
            data: Data([1, 2, 3])
        ),
        WirePacket(
            timestamp: 1_700_000_001.0,
            pid: 502,
            processName: "Safari",
            direction: 2,
            dlt: 12,
            originalLength: 64,
            data: Data([9, 9])
        )
    ]

    @Test("encodes and decodes a batch round-trip")
    func roundTrip() {
        let decoded = WirePacketBatch.decode(WirePacketBatch.encode(packets))
        #expect(decoded == packets)
    }

    @Test("decoding garbage yields an empty batch, not a crash")
    func decodeGarbage() {
        #expect(WirePacketBatch.decode(Data([0xFF, 0x00, 0x42])).isEmpty)
    }

    @Test("encoding an empty batch round-trips to empty")
    func emptyBatch() {
        #expect(WirePacketBatch.decode(WirePacketBatch.encode([])).isEmpty)
    }
}
