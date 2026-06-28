/// Parses a contiguous hex string (e.g. an RFC test vector) into bytes.
func hexBytes(_ hex: String) -> [UInt8] {
    var result = [UInt8]()
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        result.append(UInt8(hex[index ..< next], radix: 16) ?? 0)
        index = next
    }
    return result
}
