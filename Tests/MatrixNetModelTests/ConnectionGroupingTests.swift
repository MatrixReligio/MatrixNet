import Foundation
import Testing
@testable import MatrixNetModel

struct ConnectionGroupingTests {
    private func conn(
        _ name: String,
        pid: Int32,
        dst: String,
        bytesIn: UInt64,
        bytesOut: UInt64
    ) throws -> Connection {
        let source = try Endpoint(address: #require(IPAddress("192.168.1.10")), port: 50000)
        let destination = try Endpoint(address: #require(IPAddress(dst)), port: 443)
        return Connection(
            fiveTuple: FiveTuple(proto: .tcp, source: source, destination: destination),
            app: AppIdentity(pid: pid, displayName: name),
            bytesOut: bytesOut,
            bytesIn: bytesIn,
            startedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test("groups connections by app, summing bytes and count")
    func groupsByAppSummingBytesAndCount() throws {
        let connections = try [
            conn("Spark", pid: 1, dst: "1.1.1.1", bytesIn: 100, bytesOut: 50),
            conn("Spark", pid: 1, dst: "8.8.8.8", bytesIn: 200, bytesOut: 100),
            conn("Loon", pid: 2, dst: "9.9.9.9", bytesIn: 10, bytesOut: 5)
        ]
        let groups = ConnectionGrouping.byApp(connections)
        #expect(groups.count == 2)
        let spark = try #require(groups.first { $0.app.displayName == "Spark" })
        #expect(spark.connectionCount == 2)
        #expect(spark.bytesIn == 300)
        #expect(spark.bytesOut == 150)
        #expect(spark.totalBytes == 450)
    }

    @Test("sorts groups by total bytes, busiest first")
    func sortsGroupsByTotalBytesDescending() throws {
        let connections = try [
            conn("Small", pid: 1, dst: "1.1.1.1", bytesIn: 10, bytesOut: 0),
            conn("Big", pid: 2, dst: "8.8.8.8", bytesIn: 9000, bytesOut: 0)
        ]
        let groups = ConnectionGrouping.byApp(connections)
        #expect(groups.first?.app.displayName == "Big")
    }

    @Test("preserves the app's connections for drill-down, busiest first")
    func preservesUnderlyingConnectionsSortedByBytes() throws {
        let connections = try [
            conn("App", pid: 1, dst: "1.1.1.1", bytesIn: 5, bytesOut: 0),
            conn("App", pid: 1, dst: "8.8.8.8", bytesIn: 500, bytesOut: 0)
        ]
        let group = try #require(ConnectionGrouping.byApp(connections).first)
        let expected = try #require(IPAddress("8.8.8.8"))
        #expect(group.connections.count == 2)
        #expect(group.connections.first?.fiveTuple.destination.address == expected)
    }
}
