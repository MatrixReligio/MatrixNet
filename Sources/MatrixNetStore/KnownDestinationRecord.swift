import Foundation
import SwiftData

/// One destination an app has been observed reaching, keyed by app + country.
/// The set of these per app is the baseline against which new destinations are
/// detected.
@Model
public final class KnownDestinationRecord {
    public var app: String
    public var country: String
    public var firstSeen: Date

    public init(app: String, country: String, firstSeen: Date) {
        self.app = app
        self.country = country
        self.firstSeen = firstSeen
    }
}
