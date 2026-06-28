import Foundation
import Testing
@testable import MatrixNetModel

@Suite("NewDestinationDetector")
struct NewDestinationDetectorTests {
    private let now = Date(timeIntervalSince1970: 100_000)

    private func classify(_ country: String, known: Set<String>, firstSeen: Date?) -> DestinationVerdict {
        NewDestinationDetector.classify(
            country: country,
            knownCountries: known,
            appFirstSeen: firstSeen,
            now: now,
            learningWindow: 900
        )
    }

    @Test("an empty country is ignored")
    func empty() {
        #expect(classify("", known: [], firstSeen: nil) == .known)
    }

    @Test("a known country does not alert")
    func known() {
        #expect(classify("US", known: ["US"], firstSeen: now.addingTimeInterval(-100_000)) == .known)
    }

    @Test("a brand-new app only learns")
    func newApp() {
        #expect(classify("US", known: [], firstSeen: nil) == .learning)
    }

    @Test("within the learning window a new country only learns")
    func learning() {
        #expect(classify("CN", known: ["US"], firstSeen: now.addingTimeInterval(-300)) == .learning)
    }

    @Test("a new country past the learning window alerts")
    func alerts() {
        #expect(classify("CN", known: ["US"], firstSeen: now.addingTimeInterval(-1000)) == .alert)
    }
}
