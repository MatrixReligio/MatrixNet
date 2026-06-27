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
        totalConnections: 42,
        bytesIn: 123_456,
        bytesOut: 7890,
        throughputIn: 2048,
        throughputOut: 512,
        topApps: [.init(name: "Safari", bytes: 9000), .init(name: "curl", bytes: 100)],
        threatCount: 2,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    @Test("writes and reads a snapshot round-trip")
    func roundTrip() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(SharedMetricsStore.write(sample, to: url))
        let loaded = try #require(SharedMetricsStore.read(from: url))
        #expect(loaded == sample)
        #expect(loaded.totalConnections == 42)
        #expect(loaded.throughputIn == 2048)
        #expect(loaded.throughputOut == 512)
        #expect(loaded.threatCount == 2)
    }

    @Test("decodes a legacy snapshot missing the newer fields (defaults to zero)")
    func legacyDecode() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let legacy = """
        {"activeConnections":3,"bytesIn":10,"bytesOut":20,\
        "topApps":[],"updatedAt":"2023-11-14T22:13:20Z"}
        """
        try Data(legacy.utf8).write(to: url)
        let loaded = try #require(SharedMetricsStore.read(from: url))
        #expect(loaded.activeConnections == 3)
        #expect(loaded.totalConnections == 0)
        #expect(loaded.throughputIn == 0)
        #expect(loaded.throughputOut == 0)
        #expect(loaded.threatCount == 0)
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
