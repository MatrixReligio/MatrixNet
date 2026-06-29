import Foundation
import Testing
@testable import MatrixNetModel

@Suite("WidgetReloadGate")
struct WidgetReloadGateTests {
    /// App-initiated WidgetKit reloads are free of the daily budget ONLY while the
    /// containing app is in the foreground. The gate must therefore refuse to
    /// reload while backgrounded, and throttle foreground reloads so we don't
    /// re-render more often than the widget needs.
    private let now = Date(timeIntervalSince1970: 10000)

    @Test("reloads when foreground and the throttle interval has elapsed")
    func foregroundAfterInterval() {
        let gate = WidgetReloadGate(minInterval: 10)
        #expect(gate.shouldReload(isForeground: true, now: now, lastReload: now.addingTimeInterval(-10)))
    }

    @Test("does not reload while backgrounded, even after a long gap")
    func backgroundNeverReloads() {
        let gate = WidgetReloadGate(minInterval: 10)
        #expect(!gate.shouldReload(isForeground: false, now: now, lastReload: .distantPast))
    }

    @Test("throttles foreground reloads within the interval")
    func foregroundThrottled() {
        let gate = WidgetReloadGate(minInterval: 10)
        #expect(!gate.shouldReload(isForeground: true, now: now, lastReload: now.addingTimeInterval(-5)))
    }

    @Test("a never-reloaded gate fires immediately in the foreground")
    func firstForegroundFires() {
        let gate = WidgetReloadGate(minInterval: 10)
        #expect(gate.shouldReload(isForeground: true, now: now, lastReload: .distantPast))
    }
}
