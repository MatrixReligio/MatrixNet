import Foundation
import MatrixNetGeoIP
import MatrixNetModel

/// App-level access to the bundled GeoIP database (built by
/// `scripts/build-geoip.sh`). Loads lazily once; if the database is absent the
/// app simply shows no flags — address-scope classification still works.
enum GeoIP {
    private static let database: GeoIPDatabase? = {
        guard let url = Bundle.main.url(forResource: "geoip", withExtension: "dat"),
              let data = try? Data(contentsOf: url) else { return nil }
        return GeoIPDatabase(data: data)
    }()

    static func country(for address: IPAddress) -> String? {
        database?.country(for: address)
    }

    /// Flag emoji for an address's country, or `nil` if unknown.
    static func flag(for address: IPAddress) -> String? {
        country(for: address).flatMap(GeoIPDatabase.flag)
    }
}
