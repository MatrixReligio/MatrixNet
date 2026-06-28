import Foundation

/// One hourly usage bucket: bytes for an (app, host, country) within the hour
/// starting at `periodStart`.
public struct UsageRow: Sendable, Equatable {
    public let periodStart: Date
    public let app: String
    public let host: String
    public let country: String
    public var bytesIn: UInt64
    public var bytesOut: UInt64

    public init(
        periodStart: Date,
        app: String,
        host: String,
        country: String,
        bytesIn: UInt64,
        bytesOut: UInt64
    ) {
        self.periodStart = periodStart
        self.app = app
        self.host = host
        self.country = country
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}
