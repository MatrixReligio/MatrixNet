import Foundation
import MatrixNetMap

/// Loads the bundled static world map (`worldmap.dat`) once and resolves the
/// user's "home" location offline from the system region — no geolocation.
enum WorldMapStore {
    static let shared: WorldMap? = {
        guard let url = Bundle.main.url(forResource: "worldmap", withExtension: "dat"),
              let data = try? Data(contentsOf: url) else { return nil }
        return WorldMap(data: data)
    }()

    /// The home anchor: the centroid of the system's region (e.g. "US"), used as
    /// the origin of every connection arc. `nil` if unknown.
    static var homeCoordinate: MapCoordinate? {
        guard let region = Locale.current.region?.identifier else { return nil }
        return shared?.centroid(for: region)
    }
}
