import MatrixNetModel
import Testing
@testable import MatrixNetCapture

@Suite("PKTAPParser")
struct PKTAPParserTests {
    /// Builds a pktap-framed buffer: a `headerLength`-byte header (dlt/flags/pid/
    /// comm filled at their real offsets) followed by `inner`.
    private func frame(
        headerLength: UInt32 = 156,
        dlt: UInt32 = 1,
        flags: UInt32 = 0x1,
        pid: Int32 = 1234,
        comm: String = "curl",
        inner: [UInt8] = [0xAA, 0xBB, 0xCC]
    ) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: Int(headerLength))
        func putU32(_ value: UInt32, at offset: Int) {
            for index in 0 ..< 4 {
                header[offset + index] = UInt8(value >> (UInt32(index) * 8) & 0xFF)
            }
        }
        putU32(headerLength, at: 0)
        putU32(dlt, at: 8)
        putU32(flags, at: 36)
        putU32(UInt32(bitPattern: pid), at: 52)
        for (index, byte) in Array(comm.utf8).enumerated() where index < 16 {
            header[56 + index] = byte
        }
        return header + inner
    }

    @Test("parses pid, process name, dlt, and inner payload")
    func parsesFields() throws {
        let packet = try #require(PKTAPParser.parse(frame()))
        #expect(packet.pid == 1234)
        #expect(packet.processName == "curl")
        #expect(packet.dlt == 1)
        #expect(packet.payload == [0xAA, 0xBB, 0xCC])
    }

    @Test("maps direction flags (0x1 outgoing, 0x2 incoming)")
    func direction() throws {
        #expect(try #require(PKTAPParser.parse(frame(flags: 0x1))).direction == .outbound)
        #expect(try #require(PKTAPParser.parse(frame(flags: 0x2))).direction == .inbound)
        #expect(try #require(PKTAPParser.parse(frame(flags: 0x0))).direction == .unknown)
    }

    @Test("honours pth_length for the inner-packet offset")
    func variableHeaderLength() throws {
        let packet = try #require(PKTAPParser.parse(frame(headerLength: 200, inner: [1, 2])))
        #expect(packet.payload == [1, 2])
    }

    @Test("rejects buffers smaller than the header", arguments: [0, 10, 55, 72])
    func rejectsTooShort(_ length: Int) {
        #expect(PKTAPParser.parse([UInt8](repeating: 0, count: length)) == nil)
    }

    @Test("rejects a bogus pth_length that exceeds the buffer")
    func rejectsBogusLength() {
        var bytes = frame()
        // Set pth_length to a huge value.
        for index in 0 ..< 4 {
            bytes[index] = 0xFF
        }
        #expect(PKTAPParser.parse(bytes) == nil)
    }
}
