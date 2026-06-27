import Foundation
import Testing
@testable import MatrixNetModel

@Suite("ThroughputHistory")
struct ThroughputHistoryTests {
    private func sample(_ seconds: TimeInterval, _ rin: Double, _ rout: Double) -> ThroughputSample {
        ThroughputSample(time: Date(timeIntervalSince1970: seconds), inRate: rin, outRate: rout)
    }

    @Test("a new history is empty")
    func empty() {
        let history = ThroughputHistory(capacity: 60)
        #expect(history.values.isEmpty)
    }

    @Test("appends below capacity keep every sample in order")
    func belowCapacity() {
        var history = ThroughputHistory(capacity: 3)
        history.append(sample(1, 10, 1))
        history.append(sample(2, 20, 2))
        #expect(history.values.count == 2)
        #expect(history.values.first == sample(1, 10, 1))
        #expect(history.values.last == sample(2, 20, 2))
    }

    @Test("appending beyond capacity evicts the oldest sample")
    func overCapacity() {
        var history = ThroughputHistory(capacity: 3)
        for index in 1 ... 5 {
            history.append(sample(TimeInterval(index), Double(index) * 10, Double(index)))
        }
        #expect(history.values.count == 3)
        // Oldest two (t=1, t=2) evicted; window is t=3,4,5.
        #expect(history.values.map(\.inRate) == [30, 40, 50])
    }

    @Test("peak rate reports the largest in/out across the window")
    func peak() {
        var history = ThroughputHistory(capacity: 5)
        history.append(sample(1, 10, 80))
        history.append(sample(2, 90, 5))
        #expect(history.peakRate == 90)
    }
}
