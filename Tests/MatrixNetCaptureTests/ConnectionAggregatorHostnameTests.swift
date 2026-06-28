import Foundation
import MatrixNetModel
import Testing
@testable import MatrixNetCapture

@Suite("ConnectionAggregator hostname snapshot")
struct ConnectionAggregatorHostnameTests {
    @Test("a recorded hostname appears in the snapshot")
    func recordedHostnameVisible() async throws {
        let aggregator = ConnectionAggregator()
        let ip = try #require(IPAddress("1.1.1.1"))
        await aggregator.recordHostname("example.com", for: ip)
        #expect(await aggregator.hostnameSnapshot()[ip] == "example.com")
    }

    @Test("the latest recorded name for an IP wins")
    func latestWins() async throws {
        let aggregator = ConnectionAggregator()
        let ip = try #require(IPAddress("1.1.1.1"))
        await aggregator.recordHostname("old.example", for: ip)
        await aggregator.recordHostname("new.example", for: ip)
        #expect(await aggregator.hostnameSnapshot()[ip] == "new.example")
    }
}
