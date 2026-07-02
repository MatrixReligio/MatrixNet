import Foundation
import Testing
@testable import MatrixNetModel

@Suite("UsageAccumulator")
struct UsageAccumulatorTests {
    private func totals(_ inBytes: UInt64, _ outBytes: UInt64) -> UsageTotals {
        UsageTotals(bytesIn: inBytes, bytesOut: outBytes)
    }

    @Test("a brand-new key counts its full current total")
    func newKey() {
        let delta = UsageAccumulator.deltas(previous: [:], current: ["a": totals(100, 20)])
        #expect(delta == ["a": totals(100, 20)])
    }

    @Test("an advancing key counts only the positive growth")
    func growth() {
        let delta = UsageAccumulator.deltas(previous: ["a": totals(100, 20)], current: ["a": totals(150, 25)])
        #expect(delta == ["a": totals(50, 5)])
    }

    @Test("a reset counter restarts from zero and counts the new total")
    func reset() {
        // now (10/5) < was (100/20): a fresh counter grew from 0 to 10/5.
        let delta = UsageAccumulator.deltas(previous: ["a": totals(100, 20)], current: ["a": totals(10, 5)])
        #expect(delta == ["a": totals(10, 5)])
    }

    @Test("unchanged keys produce no delta")
    func unchanged() {
        let delta = UsageAccumulator.deltas(previous: ["a": totals(100, 20)], current: ["a": totals(100, 20)])
        #expect(delta.isEmpty)
    }

    @Test("mixed: one direction grows while the other resets")
    func mixed() {
        let delta = UsageAccumulator.deltas(previous: ["a": totals(100, 20)], current: ["a": totals(120, 5)])
        #expect(delta == ["a": totals(20, 5)])
    }
}

/// Each source (packet capture vs NetworkStatistics) keeps its own baseline, so
/// switching the preferred source at a capture start/stop boundary never
/// double-counts or freezes a key: a key covered by the packet source persists
/// its packet growth only, while its NStat baseline keeps advancing silently.
@Suite("UsageAccumulator sourced deltas")
struct UsageAccumulatorSourcedTests {
    private func totals(_ inBytes: UInt64, _ outBytes: UInt64 = 0) -> UsageTotals {
        UsageTotals(bytesIn: inBytes, bytesOut: outBytes)
    }

    @Test("while capturing, a packet-covered key persists the packet delta only")
    func packetWinsWhileCapturing() {
        let delta = UsageAccumulator.sourcedDeltas(
            packetPrevious: [:], packetCurrent: ["a": totals(60)],
            nstatPrevious: ["a": totals(900)], nstatCurrent: ["a": totals(960)],
            isTunnelKey: { _ in false }
        )
        #expect(delta == ["a": totals(60)])
    }

    @Test("after capture stops, NStat resumes from its own advanced baseline")
    func nstatResumesAfterCaptureStops() {
        // While capturing, the NStat baseline for "a" advanced to 960 without
        // persisting; the capture overlay is now cleared. Only the post-stop
        // growth (960 -> 970) may be persisted — not the whole capture window.
        let delta = UsageAccumulator.sourcedDeltas(
            packetPrevious: ["a": totals(300)], packetCurrent: [:],
            nstatPrevious: ["a": totals(960)], nstatCurrent: ["a": totals(970)],
            isTunnelKey: { _ in false }
        )
        #expect(delta == ["a": totals(10)])
    }

    @Test("without capture, tunnel keys are kept — NStat is the only signal")
    func tunnelKeptWithoutCapture() {
        let delta = UsageAccumulator.sourcedDeltas(
            packetPrevious: [:], packetCurrent: [:],
            nstatPrevious: [:], nstatCurrent: ["tunnel": totals(40)],
            isTunnelKey: { _ in true }
        )
        #expect(delta == ["tunnel": totals(40)])
    }

    @Test("while capturing, uncovered NStat keys persist but the tunnel relay is dropped")
    func uncoveredKeysWhileCapturing() {
        let delta = UsageAccumulator.sourcedDeltas(
            packetPrevious: [:], packetCurrent: ["a": totals(60)],
            nstatPrevious: ["b": totals(10), "t": totals(5)],
            nstatCurrent: ["b": totals(30), "t": totals(50)],
            isTunnelKey: { $0 == "t" }
        )
        #expect(delta == ["a": totals(60), "b": totals(20)])
    }
}
