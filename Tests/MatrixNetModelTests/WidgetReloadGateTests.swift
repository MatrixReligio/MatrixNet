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

    // MARK: - Publish decision (write only when the widget will read it)

    /// Foreground, reload interval elapsed: write the fresh snapshot AND reload so
    /// the nudge reads it.
    @Test("foreground at the reload interval writes and reloads together")
    func foregroundWritesAndReloads() {
        let gate = WidgetReloadGate(minInterval: 10, heartbeatInterval: 1200)
        let decision = gate.decide(
            isForeground: true,
            now: now,
            lastReload: now.addingTimeInterval(-10),
            lastWrite: now.addingTimeInterval(-2)
        )
        #expect(decision.reload)
        #expect(decision.write)
    }

    /// Foreground but within the reload throttle: neither write nor reload — the
    /// whole point: no disk write for a snapshot nothing will read yet.
    @Test("foreground within the reload interval neither writes nor reloads")
    func foregroundThrottledSkipsWrite() {
        let gate = WidgetReloadGate(minInterval: 10, heartbeatInterval: 1200)
        let decision = gate.decide(
            isForeground: true,
            now: now,
            lastReload: now.addingTimeInterval(-3),
            lastWrite: now.addingTimeInterval(-3)
        )
        #expect(!decision.reload)
        #expect(!decision.write)
    }

    /// Backgrounded: never reload (budget), but write once the heartbeat elapses
    /// so a background WidgetKit refresh (~30 min) still finds fresh-enough data.
    @Test("background writes on the heartbeat but never reloads")
    func backgroundHeartbeatWrite() {
        let gate = WidgetReloadGate(minInterval: 10, heartbeatInterval: 1200)
        let decision = gate.decide(
            isForeground: false,
            now: now,
            lastReload: .distantPast,
            lastWrite: now.addingTimeInterval(-1200)
        )
        #expect(!decision.reload)
        #expect(decision.write)
    }

    /// Backgrounded within the heartbeat: no write, no reload — fully idle, so the
    /// disk isn't touched for snapshots no one will read before the next refresh.
    @Test("background within the heartbeat is fully idle")
    func backgroundWithinHeartbeatIdle() {
        let gate = WidgetReloadGate(minInterval: 10, heartbeatInterval: 1200)
        let decision = gate.decide(
            isForeground: false,
            now: now,
            lastReload: .distantPast,
            lastWrite: now.addingTimeInterval(-600)
        )
        #expect(!decision.write)
        #expect(!decision.reload)
    }
}
