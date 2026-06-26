import Testing
@testable import MatrixNetDissection

@Suite("ByteReader")
struct ByteReaderTests {
    @Test("reads big-endian integers in sequence")
    func sequentialReads() throws {
        var reader = ByteReader([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])
        #expect(try reader.readUInt8() == 0x01)
        #expect(try reader.readUInt16() == 0x0203)
        #expect(try reader.readUInt32() == 0x0405_0607)
        #expect(reader.remaining == 0)
    }

    @Test("tracks offset and remaining")
    func offsetTracking() throws {
        var reader = ByteReader([0xAA, 0xBB, 0xCC])
        #expect(reader.offset == 0)
        #expect(reader.remaining == 3)
        _ = try reader.readUInt8()
        #expect(reader.offset == 1)
        #expect(reader.remaining == 2)
    }

    @Test("reads an exact byte slice")
    func readBytes() throws {
        var reader = ByteReader([0x10, 0x20, 0x30, 0x40])
        #expect(try reader.readBytes(2) == [0x10, 0x20])
        #expect(try reader.readBytes(2) == [0x30, 0x40])
    }

    @Test("reading zero bytes is allowed and returns empty")
    func readZeroBytes() throws {
        var reader = ByteReader([0x01])
        #expect(try reader.readBytes(0).isEmpty)
        #expect(reader.remaining == 1)
    }

    @Test("throws instead of trapping when reading past the end", arguments: [
        (0, 1), // empty buffer, read a byte
        (1, 2), // one byte, read uint16
        (3, 4) // three bytes, read uint32
    ])
    func outOfBoundsThrows(_ available: Int, _ readSize: Int) {
        var reader = ByteReader([UInt8](repeating: 0, count: available))
        #expect(throws: ByteReaderError.self) {
            switch readSize {
            case 1: _ = try reader.readUInt8()
            case 2: _ = try reader.readUInt16()
            case 4: _ = try reader.readUInt32()
            default: break
            }
        }
    }

    @Test("a failed read does not advance the offset")
    func failedReadDoesNotAdvance() {
        var reader = ByteReader([0x01])
        #expect(throws: ByteReaderError.self) { _ = try reader.readUInt32() }
        #expect(reader.offset == 0)
        #expect(reader.remaining == 1)
    }

    @Test("readBytes with a negative count throws rather than crashing")
    func negativeCountThrows() {
        var reader = ByteReader([0x01, 0x02])
        #expect(throws: ByteReaderError.self) { _ = try reader.readBytes(-5) }
    }

    @Test("readBytes past the end throws and reports availability")
    func readBytesOutOfBounds() {
        var reader = ByteReader([0x01, 0x02])
        #expect(throws: ByteReaderError.outOfBounds(requested: 5, available: 2)) {
            _ = try reader.readBytes(5)
        }
    }

    @Test("peek reads an absolute offset without advancing")
    func peekDoesNotAdvance() throws {
        var reader = ByteReader([0x01, 0x02, 0x03])
        _ = try reader.readUInt8()
        #expect(try reader.peekUInt8(at: 2) == 0x03)
        #expect(reader.offset == 1)
    }

    @Test("peek out of bounds throws", arguments: [-1, 3, 99])
    func peekOutOfBounds(_ index: Int) {
        let reader = ByteReader([0x01, 0x02, 0x03])
        #expect(throws: ByteReaderError.self) { _ = try reader.peekUInt8(at: index) }
    }

    @Test("skip advances and is bounds-checked")
    func skip() throws {
        var reader = ByteReader([0x01, 0x02, 0x03, 0x04])
        try reader.skip(3)
        #expect(reader.offset == 3)
        #expect(throws: ByteReaderError.self) { try reader.skip(2) }
    }

    @Test("honours a non-zero starting offset")
    func startingOffset() throws {
        var reader = ByteReader([0x01, 0x02, 0x03], offset: 2)
        #expect(reader.remaining == 1)
        #expect(try reader.readUInt8() == 0x03)
    }
}
