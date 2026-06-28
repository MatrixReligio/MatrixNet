import Foundation
import Testing
@testable import MatrixNetModel

@Suite("UsageBucketing")
struct UsageBucketingTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    @Test("floors a timestamp to the start of its hour")
    func floorsToHour() {
        // 1970-01-01 03:47:23 UTC → 03:00:00 UTC.
        let date = Date(timeIntervalSince1970: TimeInterval(3 * 3600 + 47 * 60 + 23))
        #expect(UsageBucketing.hourStart(of: date, calendar: utc) == Date(timeIntervalSince1970: 3 * 3600))
    }

    @Test("an exact hour is unchanged")
    func exactHour() {
        let date = Date(timeIntervalSince1970: 5 * 3600)
        #expect(UsageBucketing.hourStart(of: date, calendar: utc) == date)
    }
}
