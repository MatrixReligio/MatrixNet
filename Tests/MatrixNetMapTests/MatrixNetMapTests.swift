import CoreGraphics
import Foundation
import Testing
@testable import MatrixNetMap

@Suite("EquirectangularProjection")
struct EquirectangularProjectionTests {
    private let size = CGSize(width: 360, height: 180)

    @Test("top-left maps to the origin")
    func topLeft() {
        let point = EquirectangularProjection.point(longitude: -180, latitude: 90, in: size)
        #expect(abs(point.x) < 0.0001)
        #expect(abs(point.y) < 0.0001)
    }

    @Test("bottom-right maps to the far corner")
    func bottomRight() {
        let point = EquirectangularProjection.point(longitude: 180, latitude: -90, in: size)
        #expect(abs(point.x - 360) < 0.0001)
        #expect(abs(point.y - 180) < 0.0001)
    }

    @Test("the null island maps to the center")
    func center() {
        let point = EquirectangularProjection.point(longitude: 0, latitude: 0, in: size)
        #expect(abs(point.x - 180) < 0.0001)
        #expect(abs(point.y - 90) < 0.0001)
    }
}

@Suite("GlobeGeometry")
struct GlobeGeometryTests {
    private let unitSquare = [
        MapCoordinate(longitude: 0, latitude: 0),
        MapCoordinate(longitude: 10, latitude: 0),
        MapCoordinate(longitude: 10, latitude: 10),
        MapCoordinate(longitude: 0, latitude: 10)
    ]

    @Test("centroid of a square is its middle")
    func centroid() {
        let middle = GlobeGeometry.polygonCentroid(unitSquare)
        #expect(abs(middle.longitude - 5) < 0.0001)
        #expect(abs(middle.latitude - 5) < 0.0001)
    }

    @Test("point-in-polygon includes inside and excludes outside")
    func contains() {
        #expect(GlobeGeometry.contains(unitSquare, MapCoordinate(longitude: 5, latitude: 5)))
        #expect(!GlobeGeometry.contains(unitSquare, MapCoordinate(longitude: 50, latitude: 50)))
    }

    @Test("an arc keeps its endpoints and bows upward in the middle")
    func arc() throws {
        let points = GlobeGeometry.arcPoints(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0), samples: 10)
        #expect(points.count == 11)
        #expect(try abs(#require(points.first?.x)) < 0.0001)
        #expect(try abs(#require(points.last?.x) - 100) < 0.0001)
        // Screen y grows downward, so "up" is a smaller y at the apex.
        #expect(points[5].y < 0)
    }

    @Test("node radius is clamped and grows with traffic")
    func nodeRadius() {
        #expect(GlobeGeometry.nodeRadius(bytes: 0) == 3)
        #expect(GlobeGeometry.nodeRadius(bytes: 1 << 50) == 12)
        let small = GlobeGeometry.nodeRadius(bytes: 1 << 10)
        let large = GlobeGeometry.nodeRadius(bytes: 1 << 30)
        #expect(large > small)
        #expect(small > 3 && large < 12)
    }
}

@Suite("LandRasterizer")
struct LandRasterizerTests {
    @Test("a square polygon marks cells inside it as land")
    func rasterize() {
        let square = [[
            MapCoordinate(longitude: -10, latitude: -10),
            MapCoordinate(longitude: 10, latitude: -10),
            MapCoordinate(longitude: 10, latitude: 10),
            MapCoordinate(longitude: -10, latitude: 10)
        ]]
        let mask = LandRasterizer.rasterize(polygons: [square], gridWidth: 36, gridHeight: 18)
        #expect(mask.count == 36 * 18)
        // Cell (col 18, row 9) centers near (5, -5) — inside the square.
        #expect(mask[9 * 36 + 18])
        // Cell (col 0, row 0) centers near (-175, 85) — far outside.
        #expect(!mask[0])
    }
}

@Suite("WorldMap")
struct WorldMapTests {
    @Test("serializes and reloads land cells and centroids")
    func roundTrip() throws {
        let map = WorldMap(
            gridWidth: 4,
            gridHeight: 2,
            landCells: [LandCell(col: 1, row: 0), LandCell(col: 3, row: 1)],
            centroids: ["US": MapCoordinate(longitude: -98.5, latitude: 39.8)]
        )
        let reloaded = try #require(WorldMap(data: map.serialized()))
        #expect(reloaded.gridWidth == 4)
        #expect(reloaded.gridHeight == 2)
        #expect(Set(reloaded.landCells) == Set([LandCell(col: 1, row: 0), LandCell(col: 3, row: 1)]))
        let centroid = try #require(reloaded.centroid(for: "US"))
        #expect(abs(centroid.longitude - -98.5) < 0.05)
        #expect(abs(centroid.latitude - 39.8) < 0.05)
    }
}
