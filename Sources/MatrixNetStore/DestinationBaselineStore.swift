import Foundation
import SwiftData

/// The set of countries each app has reached so far, plus when the app was first
/// observed — the baseline a new-destination detector classifies against.
public struct AppBaseline: Sendable {
    public var countries: Set<String>
    public var firstSeen: Date

    public init(countries: Set<String>, firstSeen: Date) {
        self.countries = countries
        self.firstSeen = firstSeen
    }
}

/// Persists the per-app destination baseline with SwiftData, deduped by
/// app + country.
@MainActor
public final class DestinationBaselineStore {
    private let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }

    /// An in-memory store for tests and previews.
    public static func inMemory() throws -> DestinationBaselineStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: KnownDestinationRecord.self, configurations: config)
        return DestinationBaselineStore(container: container)
    }

    /// A persistent store under Application Support.
    public static func persistent() throws -> DestinationBaselineStore {
        try DestinationBaselineStore(container: ModelContainer(for: KnownDestinationRecord.self))
    }

    /// Records that `app` reached `country`, ignoring duplicates.
    public func record(app: String, country: String, at firstSeen: Date) throws {
        let context = container.mainContext
        var descriptor = FetchDescriptor<KnownDestinationRecord>(
            predicate: #Predicate { $0.app == app && $0.country == country }
        )
        descriptor.fetchLimit = 1
        if try context.fetch(descriptor).first != nil { return }
        context.insert(KnownDestinationRecord(app: app, country: country, firstSeen: firstSeen))
        try context.save()
    }

    /// The full baseline, grouped by app: the set of countries and the earliest
    /// time the app was observed.
    public func load() throws -> [String: AppBaseline] {
        let records = try container.mainContext.fetch(FetchDescriptor<KnownDestinationRecord>())
        var baseline: [String: AppBaseline] = [:]
        for record in records {
            if var existing = baseline[record.app] {
                existing.countries.insert(record.country)
                existing.firstSeen = min(existing.firstSeen, record.firstSeen)
                baseline[record.app] = existing
            } else {
                baseline[record.app] = AppBaseline(countries: [record.country], firstSeen: record.firstSeen)
            }
        }
        return baseline
    }
}
