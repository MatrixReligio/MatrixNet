import Foundation
import SwiftData

/// One TLS client fingerprint an app has used, keyed by app + JA4. The set of
/// these per app records which TLS stacks a process has been seen using, with
/// the first/last time observed and how many times.
@Model
public final class AppFingerprintRecord {
    // Serves the (app, ja4) upsert lookup.
    #Index<AppFingerprintRecord>([\.app, \.ja4])

    public var app: String
    public var ja4: String
    public var label: String?
    public var transport: String
    public var firstSeen: Date
    public var lastSeen: Date
    public var count: Int

    public init(
        app: String,
        ja4: String,
        label: String?,
        transport: String,
        firstSeen: Date,
        lastSeen: Date,
        count: Int
    ) {
        self.app = app
        self.ja4 = ja4
        self.label = label
        self.transport = transport
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.count = count
    }
}
