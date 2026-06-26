import Foundation
import Testing
@testable import MatrixNetModel

@Suite("MetricsSnapshot & SharedMetricsStore")
struct MetricsSnapshotTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mn-metrics-\(UInt64.random(in: 0 ..< .max)).json")
    }

    private let sample = MetricsSnapshot(
        activeConnections: 7,
        bytesIn: 123_456,
        bytesOut: 7890,
        topApps: [.init(name: "Safari", bytes: 9000), .init(name: "curl", bytes: 100)],
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    @Test("writes and reads a snapshot round-trip")
    func roundTrip() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(SharedMetricsStore.write(sample, to: url))
        let loaded = try #require(SharedMetricsStore.read(from: url))
        #expect(loaded == sample)
    }

    @Test("reading a missing file returns nil")
    func missingFile() {
        #expect(SharedMetricsStore.read(from: tempURL()) == nil)
    }

    @Test("reading corrupt JSON returns nil rather than crashing")
    func corruptFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        #expect(SharedMetricsStore.read(from: url) == nil)
    }
}
