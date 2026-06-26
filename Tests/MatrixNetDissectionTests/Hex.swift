import Foundation

/// Test helper: builds a byte array from a hex string, ignoring whitespace.
/// Crashes the test (intentionally) on malformed hex so fixtures stay honest.
func hex(_ string: String) -> [UInt8] {
    let cleaned = string.filter { !$0.isWhitespace }
    precondition(cleaned.count.isMultiple(of: 2), "hex string must have an even length")
    var bytes = [UInt8]()
    bytes.reserveCapacity(cleaned.count / 2)
    var index = cleaned.startIndex
    while index < cleaned.endIndex {
        let next = cleaned.index(index, offsetBy: 2)
        guard let byte = UInt8(cleaned[index ..< next], radix: 16) else {
            preconditionFailure("invalid hex byte: \(cleaned[index ..< next])")
        }
        bytes.append(byte)
        index = next
    }
    return bytes
}
