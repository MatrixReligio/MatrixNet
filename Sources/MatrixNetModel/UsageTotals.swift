import Foundation

/// Inbound/outbound byte counters for one app, destination, or bucket.
public struct UsageTotals: Sendable, Equatable {
    public var bytesIn: UInt64
    public var bytesOut: UInt64

    public init(bytesIn: UInt64 = 0, bytesOut: UInt64 = 0) {
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }

    public static func + (lhs: UsageTotals, rhs: UsageTotals) -> UsageTotals {
        UsageTotals(bytesIn: lhs.bytesIn + rhs.bytesIn, bytesOut: lhs.bytesOut + rhs.bytesOut)
    }
}
