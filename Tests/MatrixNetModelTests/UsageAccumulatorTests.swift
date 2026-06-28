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
