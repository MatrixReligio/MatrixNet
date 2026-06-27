import Foundation
import MatrixNetMap

// Converts a Natural Earth admin-0 countries GeoJSON into the compact, static
// `worldmap.dat` bundled with the app: a dotted land grid plus per-country
// centroids. Run via `scripts/build-worldmap.sh`.
//
// Usage: MapConvert <input.geojson> <output.dat> [gridWidth gridHeight]

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: MapConvert <input.geojson> <output.dat> [gridW gridH]\n".utf8))
    exit(2)
}

let inputPath = arguments[1]
let outputPath = arguments[2]
let gridWidth = arguments.count > 3 ? (Int(arguments[3]) ?? 180) : 180
let gridHeight = arguments.count > 4 ? (Int(arguments[4]) ?? 90) : 90

func coordinate(_ any: Any) -> MapCoordinate? {
    guard let pair = any as? [Any], pair.count >= 2,
          let lon = (pair[0] as? NSNumber)?.doubleValue,
          let lat = (pair[1] as? NSNumber)?.doubleValue else { return nil }
    return MapCoordinate(longitude: lon, latitude: lat)
}

func ring(_ any: Any) -> [MapCoordinate] {
    (any as? [Any])?.compactMap(coordinate) ?? []
}

func polygonRings(_ any: Any) -> [[MapCoordinate]] {
    (any as? [Any])?.map(ring) ?? []
}

func ringArea(_ ring: [MapCoordinate]) -> Double {
    guard ring.count > 2 else { return 0 }
    var area = 0.0
    for index in 0 ..< ring.count {
        let a = ring[index]
        let b = ring[(index + 1) % ring.count]
        area += a.longitude * b.latitude - b.longitude * a.latitude
    }
    return abs(area) / 2
}

let data = try Data(contentsOf: URL(fileURLWithPath: inputPath))
guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let features = json["features"] as? [[String: Any]] else {
    FileHandle.standardError.write(Data("error: not a GeoJSON FeatureCollection\n".utf8))
    exit(1)
}

var allPolygons: [[[MapCoordinate]]] = []
var centroids: [String: MapCoordinate] = [:]

for feature in features {
    let properties = feature["properties"] as? [String: Any] ?? [:]
    let geometry = feature["geometry"] as? [String: Any] ?? [:]
    let type = geometry["type"] as? String ?? ""
    let coordinates = geometry["coordinates"] ?? []

    var polygons: [[[MapCoordinate]]] = []
    switch type {
    case "Polygon":
        polygons = [polygonRings(coordinates)]
    case "MultiPolygon":
        polygons = (coordinates as? [Any])?.map(polygonRings) ?? []
    default:
        break
    }
    allPolygons.append(contentsOf: polygons)

    var iso = (properties["ISO_A2"] as? String) ?? "-99"
    if iso == "-99" || iso.count != 2 {
        iso = (properties["ISO_A2_EH"] as? String) ?? iso
    }
    guard iso.count == 2, iso != "-99" else { continue }
    // Use the largest polygon's outer ring so islands don't pull the centroid off.
    if let largest = polygons.max(by: { ringArea($0.first ?? []) < ringArea($1.first ?? []) }),
       let outer = largest.first, !outer.isEmpty {
        centroids[iso] = GlobeGeometry.polygonCentroid(outer)
    }
}

let mask = LandRasterizer.rasterize(polygons: allPolygons, gridWidth: gridWidth, gridHeight: gridHeight)
var cells: [LandCell] = []
for row in 0 ..< gridHeight {
    for col in 0 ..< gridWidth where mask[row * gridWidth + col] {
        cells.append(LandCell(col: col, row: row))
    }
}

let map = WorldMap(gridWidth: gridWidth, gridHeight: gridHeight, landCells: cells, centroids: centroids)
try map.serialized().write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath): \(cells.count) land cells, \(centroids.count) centroids, grid \(gridWidth)x\(gridHeight)")
