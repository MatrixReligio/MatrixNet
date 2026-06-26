import Foundation
import SwiftData

/// A persisted summary of a connection seen over time, keyed by app + remote +
/// protocol so repeat sightings accumulate rather than duplicating.
@Model
public final class ConnectionHistoryRecord {
    public var appName: String
    public var remoteHost: String
    public var proto: String
    public var firstSeen: Date
    public var lastSeen: Date
    public var bytesIn: Int
    public var bytesOut: Int
    public var sightings: Int

    public init(
        appName: String,
        remoteHost: String,
        proto: String,
        firstSeen: Date,
        lastSeen: Date,
        bytesIn: Int,
        bytesOut: Int,
        sightings: Int = 1
    ) {
        self.appName = appName
        self.remoteHost = remoteHost
        self.proto = proto
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.sightings = sightings
    }
}

/// A connection observation handed to the store (decoupled from the model layer).
public struct ConnectionSummary: Sendable {
    public let appName: String
    public let remoteHost: String
    public let proto: String
    public let bytesIn: Int
    public let bytesOut: Int
    public let at: Date

    public init(appName: String, remoteHost: String, proto: String, bytesIn: Int, bytesOut: Int, at: Date) {
        self.appName = appName
        self.remoteHost = remoteHost
        self.proto = proto
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.at = at
    }
}
