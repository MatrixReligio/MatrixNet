import Foundation
import Testing
@testable import MatrixNetModel

@Suite("ThreatNotificationPolicy")
struct ThreatNotificationPolicyTests {
    @Test("first hit for a key notifies; a repeat within the window is suppressed")
    func dedup() {
        var policy = ThreatNotificationPolicy(perKeyWindow: 60, globalMinGap: 0)
        let start = Date(timeIntervalSince1970: 1000)
        #expect(policy.shouldNotify(key: "a", now: start) == true)
        #expect(policy.shouldNotify(key: "a", now: start.addingTimeInterval(30)) == false)
        #expect(policy.shouldNotify(key: "a", now: start.addingTimeInterval(61)) == true)
    }

    @Test("distinct keys notify independently when there is no global gap")
    func distinct() {
        var policy = ThreatNotificationPolicy(perKeyWindow: 60, globalMinGap: 0)
        let start = Date(timeIntervalSince1970: 1000)
        #expect(policy.shouldNotify(key: "a", now: start) == true)
        #expect(policy.shouldNotify(key: "b", now: start.addingTimeInterval(1)) == true)
    }

    @Test("the global minimum gap throttles bursts across keys")
    func globalGap() {
        var policy = ThreatNotificationPolicy(perKeyWindow: 60, globalMinGap: 10)
        let start = Date(timeIntervalSince1970: 1000)
        #expect(policy.shouldNotify(key: "a", now: start) == true)
        #expect(policy.shouldNotify(key: "b", now: start.addingTimeInterval(5)) == false)
        #expect(policy.shouldNotify(key: "b", now: start.addingTimeInterval(11)) == true)
    }
}
