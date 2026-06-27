import Foundation
import MatrixNetMap
import MatrixNetModel

/// Loads the bundled static world map (`worldmap.dat`) once and resolves the
/// user's "home" location offline from the system region — no geolocation.
enum WorldMapStore {
    static let shared: WorldMap? = {
        guard let url = Bundle.main.url(forResource: "worldmap", withExtension: "dat"),
              let data = try? Data(contentsOf: url) else { return nil }
        return WorldMap(data: data)
    }()

    /// The home anchor: the centroid of the user-chosen region, or the system's
    /// region when none is set (the system region can differ from the physical
    /// location). Used as the origin of every connection arc. `nil` if unknown.
    static var homeCoordinate: MapCoordinate? {
        guard let region = homeRegion else { return nil }
        return shared?.centroid(for: region)
    }

    /// The effective home ISO-2 region: the user override, else the system region.
    static var homeRegion: String? {
        let preference = Preferences(defaults: SharedMetricsStore.sharedDefaults ?? .standard).homeRegion
        return preference ?? Locale.current.region?.identifier
    }

    /// ISO-2 regions that have a centroid in the bundled map, for the Settings
    /// picker — sorted by their localized display name.
    static var selectableRegions: [String] {
        guard let world = shared else { return [] }
        return Locale.Region.isoRegions
            .map(\.identifier)
            .filter { $0.count == 2 && world.centroid(for: $0) != nil }
            .sorted {
                let lhs = Locale.current.localizedString(forRegionCode: $0) ?? $0
                let rhs = Locale.current.localizedString(forRegionCode: $1) ?? $1
                return lhs.localizedCompare(rhs) == .orderedAscending
            }
    }
}
