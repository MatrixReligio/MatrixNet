import Foundation
import Testing
@testable import MatrixNetModel

@Suite("Connection")
struct ConnectionTests {
    private func makeConnection(start: Date) throws -> Connection {
        let source = try Endpoint(address: #require(IPAddress("192.168.1.5")), port: 50000)
        let destination = try Endpoint(address: #require(IPAddress("1.1.1.1")), port: 443)
        return Connection(
            fiveTuple: FiveTuple(proto: .tcp, source: source, destination: destination),
            app: AppIdentity(pid: 501, displayName: "curl"),
            startedAt: start
        )
    }

    @Test("total bytes sum both directions")
    func totalBytes() throws {
        var connection = try makeConnection(start: Date(timeIntervalSince1970: 0))
        connection.bytesIn = 300
        connection.bytesOut = 200
        #expect(connection.totalBytes == 500)
    }

    @Test("updating counts advances last activity when bytes increase")
    func updateAdvancesActivity() throws {
        let start = Date(timeIntervalSince1970: 1000)
        var connection = try makeConnection(start: start)
        let later = Date(timeIntervalSince1970: 1005)

        connection.updateCumulativeCounts(bytesIn: 100, bytesOut: 50, at: later)

        #expect(connection.bytesIn == 100)
        #expect(connection.bytesOut == 50)
        #expect(connection.lastActivityAt == later)
    }

    @Test("idle refresh with unchanged counts does not advance last activity")
    func idleRefreshKeepsActivity() throws {
        let start = Date(timeIntervalSince1970: 1000)
        var connection = try makeConnection(start: start)
        connection.updateCumulativeCounts(bytesIn: 100, bytesOut: 50, at: Date(timeIntervalSince1970: 1005))
        let activityAfterFirst = connection.lastActivityAt

        // Same cumulative counters arrive later: no real traffic happened.
        connection.updateCumulativeCounts(bytesIn: 100, bytesOut: 50, at: Date(timeIntervalSince1970: 1010))

        #expect(connection.lastActivityAt == activityAfterFirst)
    }

    @Test("cumulative counters are monotonic and never regress")
    func countersNeverRegress() throws {
        var connection = try makeConnection(start: Date(timeIntervalSince1970: 0))
        connection.updateCumulativeCounts(bytesIn: 500, bytesOut: 500, at: Date(timeIntervalSince1970: 1))
        // A stale/smaller sample must not lower the counters.
        connection.updateCumulativeCounts(bytesIn: 10, bytesOut: 10, at: Date(timeIntervalSince1970: 2))
        #expect(connection.bytesIn == 500)
        #expect(connection.bytesOut == 500)
    }

    @Test("packet counters update monotonically and advance activity")
    func packetCountersMonotonic() throws {
        let start = Date(timeIntervalSince1970: 0)
        var connection = try makeConnection(start: start)
        connection.updateCumulativeCounts(
            bytesIn: 0,
            bytesOut: 0,
            packetsIn: 4,
            packetsOut: 3,
            at: Date(timeIntervalSince1970: 5)
        )
        #expect(connection.packetsIn == 4)
        #expect(connection.packetsOut == 3)
        #expect(connection.lastActivityAt == Date(timeIntervalSince1970: 5))

        // Stale smaller packet sample must not regress.
        connection.updateCumulativeCounts(
            bytesIn: 0,
            bytesOut: 0,
            packetsIn: 1,
            packetsOut: 1,
            at: Date(timeIntervalSince1970: 9)
        )
        #expect(connection.packetsIn == 4)
        #expect(connection.packetsOut == 3)
    }

    @Test("totalBytes uses documented wrapping semantics at the UInt64 boundary")
    func totalBytesWraps() throws {
        var connection = try makeConnection(start: Date(timeIntervalSince1970: 0))
        connection.bytesIn = .max
        connection.bytesOut = 1
        #expect(connection.totalBytes == 0)
    }

    @Test("equatable: identical connections compare equal, differing byte counts do not")
    func equatable() throws {
        let id = UUID()
        let start = Date(timeIntervalSince1970: 100)
        let source = try Endpoint(address: #require(IPAddress("192.168.1.5")), port: 50000)
        let destination = try Endpoint(address: #require(IPAddress("1.1.1.1")), port: 443)
        func make(bytesIn: UInt64) -> Connection {
            Connection(
                id: id,
                fiveTuple: FiveTuple(proto: .tcp, source: source, destination: destination),
                app: AppIdentity(pid: 501, displayName: "curl"),
                bytesIn: bytesIn,
                startedAt: start
            )
        }
        // The publish-layer diff gate relies on this: an unchanged snapshot must
        // compare equal so it isn't republished (and re-rendered) every tick.
        #expect(make(bytesIn: 42) == make(bytesIn: 42))
        #expect(make(bytesIn: 42) != make(bytesIn: 43))
    }
}
