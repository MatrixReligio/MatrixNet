import Foundation

/// A land cell on the equirectangular grid (column from the left, row from the top).
public struct LandCell: Equatable, Hashable, Sendable {
    public let col: Int
    public let row: Int

    public init(col: Int, row: Int) {
        self.col = col
        self.row = row
    }
}

/// The bundled, static world map: a dotted land grid plus a per-country centroid
/// table. Built once from Natural Earth 1:110m by `MapConvert` and shipped in the
/// app — coastlines do not move, so it never needs updating.
///
/// Binary format (big-endian):
/// `gridW: UInt16, gridH: UInt16, landCount: UInt32, landCount × cellIndex:
/// UInt32, centroidCount: UInt16, centroidCount × (ISO-2: 2 bytes, lat×100:
/// Int16, lon×100: Int16)`.
public struct WorldMap: Sendable {
    public let gridWidth: Int
    public let gridHeight: Int
    public let landCells: [LandCell]
    private let centroidTable: [String: MapCoordinate]

    public init(
        gridWidth: Int,
        gridHeight: Int,
        landCells: [LandCell],
        centroids: [String: MapCoordinate]
    ) {
        self.gridWidth = gridWidth
        self.gridHeight = gridHeight
        self.landCells = landCells
        centroidTable = centroids
    }

    /// The representative coordinate for an ISO 3166-1 alpha-2 country code.
    public func centroid(for iso2: String) -> MapCoordinate? {
        centroidTable[iso2.uppercased()]
    }

    public func serialized() -> Data {
        var data = Data()
        func appendUInt16(_ value: Int) {
            var big = UInt16(truncatingIfNeeded: value).bigEndian
            withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
        }
        func appendUInt32(_ value: Int) {
            var big = UInt32(truncatingIfNeeded: value).bigEndian
            withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
        }
        func appendInt16(_ value: Int) {
            var big = Int16(clamping: value).bigEndian
            withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
        }

        appendUInt16(gridWidth)
        appendUInt16(gridHeight)
        appendUInt32(landCells.count)
        for cell in landCells {
            appendUInt32(cell.row * gridWidth + cell.col)
        }
        appendUInt16(centroidTable.count)
        for (iso, coordinate) in centroidTable.sorted(by: { $0.key < $1.key }) {
            let bytes = Array(iso.utf8.prefix(2))
            data.append(bytes.count == 2 ? bytes[0] : 0x3F)
            data.append(bytes.count == 2 ? bytes[1] : 0x3F)
            appendInt16(Int((coordinate.latitude * 100).rounded()))
            appendInt16(Int((coordinate.longitude * 100).rounded()))
        }
        return data
    }

    public init?(data: Data) {
        let bytes = [UInt8](data)
        var offset = 0
        func readUInt16() -> Int? {
            guard offset + 2 <= bytes.count else { return nil }
            defer { offset += 2 }
            return Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
        }
        func readUInt32() -> Int? {
            guard offset + 4 <= bytes.count else { return nil }
            var value = 0
            for _ in 0 ..< 4 {
                value = value << 8 | Int(bytes[offset])
                offset += 1
            }
            return value
        }
        func readInt16() -> Int? {
            guard offset + 2 <= bytes.count else { return nil }
            defer { offset += 2 }
            return Int(Int16(bitPattern: UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])))
        }

        guard let width = readUInt16(), let height = readUInt16(), width > 0, height > 0 else { return nil }
        guard let landCount = readUInt32() else { return nil }
        var cells = [LandCell]()
        cells.reserveCapacity(landCount)
        for _ in 0 ..< landCount {
            guard let index = readUInt32() else { return nil }
            cells.append(LandCell(col: index % width, row: index / width))
        }
        guard let centroidCount = readUInt16() else { return nil }
        var table = [String: MapCoordinate]()
        for _ in 0 ..< centroidCount {
            guard offset + 2 <= bytes.count else { return nil }
            let iso = String(bytes: bytes[offset ..< offset + 2], encoding: .utf8) ?? "??"
            offset += 2
            guard let lat = readInt16(), let lon = readInt16() else { return nil }
            table[iso] = MapCoordinate(longitude: Double(lon) / 100, latitude: Double(lat) / 100)
        }
        gridWidth = width
        gridHeight = height
        landCells = cells
        centroidTable = table
    }
}
