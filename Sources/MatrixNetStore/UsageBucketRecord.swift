import Foundation
import SwiftData

/// One persisted hourly usage bucket. Bytes are `Int` because SwiftData cannot
/// store `UInt64`; traffic volumes stay well within `Int.max`.
@Model
public final class UsageBucketRecord {
    public var periodStart: Date
    public var app: String
    public var host: String
    public var country: String
    public var bytesIn: Int
    public var bytesOut: Int

    public init(
        periodStart: Date,
        app: String,
        host: String,
        country: String,
        bytesIn: Int,
        bytesOut: Int
    ) {
        self.periodStart = periodStart
        self.app = app
        self.host = host
        self.country = country
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}
