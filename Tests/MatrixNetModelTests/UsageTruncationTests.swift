import Foundation
import Testing
@testable import MatrixNetModel

@Suite("UsageTruncation")
struct UsageTruncationTests {
    private let hour = Date(timeIntervalSince1970: 0)
    private func row(_ app: String, _ host: String, _ bytes: UInt64) -> UsageRow {
        UsageRow(periodStart: hour, app: app, host: host, country: "US", bytesIn: bytes, bytesOut: 0)
    }

    @Test("groups with at most n hosts are returned unchanged")
    func underLimit() {
        let rows = [row("A", "x.com", 10), row("A", "y.com", 5)]
        let out = UsageTruncation.topN(rows, limit: 5)
        #expect(out.count == 2)
    }

    @Test("the long tail past the top n folds into one ·other row")
    func foldsTail() {
        let rows = [row("A", "a", 100), row("A", "b", 50), row("A", "c", 9), row("A", "d", 1)]
        let out = UsageTruncation.topN(rows, limit: 2)
        #expect(out.count == 3) // a, b, ·other
        let other = out.first { $0.host == UsageTruncation.otherHost }
        #expect(other?.bytesIn == 10) // 9 + 1
        #expect(other?.country == UsageTruncation.mixedCountry)
    }

    @Test("each app is truncated independently")
    func perApp() {
        let rows = [row("A", "a", 5), row("A", "b", 4), row("A", "c", 3), row("B", "z", 1)]
        let out = UsageTruncation.topN(rows, limit: 2)
        #expect(out.count(where: { $0.app == "A" }) == 3) // a, b, ·other
        #expect(out.count(where: { $0.app == "B" }) == 1)
    }
}
