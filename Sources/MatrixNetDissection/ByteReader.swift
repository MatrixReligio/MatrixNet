/// An error thrown when a read would go past the end of the buffer.
public enum ByteReaderError: Error, Equatable {
    case outOfBounds(requested: Int, available: Int)
}

/// A bounds-checked, big-endian cursor over a byte buffer.
///
/// Every read validates the requested length against the remaining bytes and
/// throws `ByteReaderError.outOfBounds` instead of trapping. This is the safety
/// foundation for all protocol dissection: malformed or truncated packets must
/// never crash, loop forever, or read out of bounds.
public struct ByteReader {
    private let bytes: [UInt8]
    /// The current read position, measured from the start of the buffer.
    public private(set) var offset: Int

    public init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    /// The number of bytes left to read.
    public var remaining: Int {
        max(0, bytes.count - offset)
    }

    /// Reads one byte and advances.
    public mutating func readUInt8() throws -> UInt8 {
        try ensure(1)
        defer { offset += 1 }
        return bytes[offset]
    }

    /// Reads a big-endian 16-bit value and advances.
    public mutating func readUInt16() throws -> UInt16 {
        try ensure(2)
        defer { offset += 2 }
        return (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    /// Reads a big-endian 32-bit value and advances.
    public mutating func readUInt32() throws -> UInt32 {
        try ensure(4)
        defer { offset += 4 }
        var value: UInt32 = 0
        for index in 0 ..< 4 {
            value = (value << 8) | UInt32(bytes[offset + index])
        }
        return value
    }

    /// Reads `count` bytes and advances.
    public mutating func readBytes(_ count: Int) throws -> [UInt8] {
        try ensure(count)
        defer { offset += count }
        return Array(bytes[offset ..< offset + count])
    }

    /// Reads a byte at an absolute buffer offset without advancing.
    public func peekUInt8(at absoluteOffset: Int) throws -> UInt8 {
        guard absoluteOffset >= 0, absoluteOffset < bytes.count else {
            throw ByteReaderError.outOfBounds(requested: 1, available: max(0, bytes.count - absoluteOffset))
        }
        return bytes[absoluteOffset]
    }

    /// Advances by `count` bytes without returning them.
    public mutating func skip(_ count: Int) throws {
        try ensure(count)
        offset += count
    }

    /// Validates that `count` bytes can be read; throws otherwise. Never mutates.
    private func ensure(_ count: Int) throws {
        guard count >= 0, count <= remaining else {
            throw ByteReaderError.outOfBounds(requested: count, available: remaining)
        }
    }
}
