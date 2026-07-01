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

    @Test("round-trips edge cases: unicode name, empty name, empty/large payloads")
    func edgeCases() {
        let edge = [
            WirePacket(
                timestamp: 0,
                pid: -1,
                processName: "进程名 🛰️",
                direction: 0,
                dlt: 0,
                originalLength: 0,
                data: Data()
            ),
            WirePacket(
                timestamp: 1.25e9,
                pid: 2_147_483_647,
                processName: "",
                direction: 255,
                dlt: 4_294_967_295,
                originalLength: 9000,
                data: Data(repeating: 0xAB, count: 4096)
            )
        ]
        #expect(WirePacketBatch.decode(WirePacketBatch.encode(edge)) == edge)
    }

    @Test("a truncated batch decodes to empty rather than crashing")
    func truncated() {
        let full = WirePacketBatch.encode(packets)
        #expect(WirePacketBatch.decode(full.prefix(full.count - 1)).isEmpty)
        #expect(WirePacketBatch.decode(full.prefix(2)).isEmpty)
    }

    @Test("decodes correctly from a Data slice whose start index is non-zero")
    func slicedInput() {
        // The zero-copy decode reads via withUnsafeBytes, which is 0-based over the
        // slice's own region — this guards that a non-zero startIndex is respected
        // and never reads the prefix bytes.
        var padded = Data([0xDE, 0xAD, 0xBE, 0xEF])
        padded.append(WirePacketBatch.encode(packets))
        let slice = padded.suffix(from: padded.startIndex + 4)
        #expect(slice.startIndex != 0)
        #expect(WirePacketBatch.decode(slice) == packets)
    }
}
