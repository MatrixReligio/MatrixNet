import CoreGraphics
import Foundation

/// A geographic coordinate in degrees (longitude −180…180, latitude −90…90).
public struct MapCoordinate: Equatable, Sendable {
    public var longitude: Double
    public var latitude: Double

    public init(longitude: Double, latitude: Double) {
        self.longitude = longitude
        self.latitude = latitude
    }
}

/// The simple equirectangular (plate carrée) projection used to lay the world out
/// on a flat canvas: longitude maps linearly to x, latitude to y.
public enum EquirectangularProjection {
    public static func point(longitude: Double, latitude: Double, in size: CGSize) -> CGPoint {
        CGPoint(
            x: (longitude + 180) / 360 * size.width,
            y: (90 - latitude) / 180 * size.height
        )
    }

    public static func point(_ coordinate: MapCoordinate, in size: CGSize) -> CGPoint {
        point(longitude: coordinate.longitude, latitude: coordinate.latitude, in: size)
    }
}

/// Pure geometry helpers shared by the renderer and the dataset converter.
public enum GlobeGeometry {
    /// Area-weighted centroid of a polygon ring (shoelace), falling back to the
    /// vertex average for degenerate rings.
    public static func polygonCentroid(_ ring: [MapCoordinate]) -> MapCoordinate {
        let count = ring.count
        guard count > 0 else { return MapCoordinate(longitude: 0, latitude: 0) }
        var area = 0.0
        var centroidX = 0.0
        var centroidY = 0.0
        for index in 0 ..< count {
            let current = ring[index]
            let next = ring[(index + 1) % count]
            let cross = current.longitude * next.latitude - next.longitude * current.latitude
            area += cross
            centroidX += (current.longitude + next.longitude) * cross
            centroidY += (current.latitude + next.latitude) * cross
        }
        area *= 0.5
        guard abs(area) > 1e-12 else {
            let lon = ring.reduce(0) { $0 + $1.longitude } / Double(count)
            let lat = ring.reduce(0) { $0 + $1.latitude } / Double(count)
            return MapCoordinate(longitude: lon, latitude: lat)
        }
        return MapCoordinate(longitude: centroidX / (6 * area), latitude: centroidY / (6 * area))
    }

    /// Even-odd ray-casting point-in-polygon test.
    public static func contains(_ ring: [MapCoordinate], _ point: MapCoordinate) -> Bool {
        var inside = false
        let count = ring.count
        var previous = count - 1
        for index in 0 ..< count {
            let current = ring[index]
            let prior = ring[previous]
            if (current.latitude > point.latitude) != (prior.latitude > point.latitude) {
                let slope = (point.latitude - current.latitude) / (prior.latitude - current.latitude)
                let xCross = current.longitude + slope * (prior.longitude - current.longitude)
                if point.longitude < xCross { inside.toggle() }
            }
            previous = index
        }
        return inside
    }

    /// Sampled points along a quadratic arc that bows upward (toward smaller y) so
    /// connection links read as great-circle-style sweeps rather than straight
    /// lines. Returns `samples + 1` points from `from` to `to`.
    public static func arcPoints(from: CGPoint, to: CGPoint, samples: Int) -> [CGPoint] {
        let steps = max(1, samples)
        let dx = to.x - from.x
        let dy = to.y - from.y
        let distance = (dx * dx + dy * dy).squareRoot()
        let lift = max(12, distance * 0.22)
        let control = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2 - lift)
        var points: [CGPoint] = []
        points.reserveCapacity(steps + 1)
        for step in 0 ... steps {
            let fraction = CGFloat(step) / CGFloat(steps)
            let inverse = 1 - fraction
            points.append(
                CGPoint(
                    x: inverse * inverse * from.x + 2 * inverse * fraction * control.x + fraction * fraction * to.x,
                    y: inverse * inverse * from.y + 2 * inverse * fraction * control.y + fraction * fraction * to.y
                )
            )
        }
        return points
    }

    /// A log-scaled node radius for a flow's byte total, clamped to [min, max].
    public static func nodeRadius(bytes: UInt64, min minRadius: CGFloat = 3, max maxRadius: CGFloat = 12) -> CGFloat {
        let cap = 10.0 // ~10^10 bytes (10 GB) reaches the max radius.
        let scaled = Swift.min(1.0, Swift.max(0.0, log10(Double(bytes) + 1) / cap))
        return minRadius + (maxRadius - minRadius) * CGFloat(scaled)
    }
}

/// Rasterizes country/land polygons onto an equirectangular boolean grid: a cell
/// is land if its center lies inside an outer ring and outside that polygon's
/// holes. Used by the dataset converter to build the dotted base map.
public enum LandRasterizer {
    /// `polygons` is a list of polygons; each polygon is a list of rings (the
    /// first ring is the outer boundary, the rest are holes).
    public static func rasterize(
        polygons: [[[MapCoordinate]]],
        gridWidth: Int,
        gridHeight: Int
    ) -> [Bool] {
        var mask = [Bool](repeating: false, count: gridWidth * gridHeight)
        for row in 0 ..< gridHeight {
            let lat = 90 - (Double(row) + 0.5) * 180 / Double(gridHeight)
            for col in 0 ..< gridWidth {
                let lon = -180 + (Double(col) + 0.5) * 360 / Double(gridWidth)
                let point = MapCoordinate(longitude: lon, latitude: lat)
                mask[row * gridWidth + col] = isLand(point, in: polygons)
            }
        }
        return mask
    }

    private static func isLand(_ point: MapCoordinate, in polygons: [[[MapCoordinate]]]) -> Bool {
        for polygon in polygons {
            guard let outer = polygon.first, GlobeGeometry.contains(outer, point) else { continue }
            let inHole = polygon.dropFirst().contains { GlobeGeometry.contains($0, point) }
            if !inHole { return true }
        }
        return false
    }
}
