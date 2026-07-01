import Foundation
import Testing
@testable import MatrixNetMap

@Suite("GlobeAnimation schedule")
struct GlobeAnimationTests {
    @Test("pauses when the app is not frontmost, whatever is on the map")
    func pausedWhenInactive() {
        #expect(GlobeAnimation.schedule(active: false, destinationCount: 0).paused)
        #expect(GlobeAnimation.schedule(active: false, destinationCount: 12).paused)
    }

    @Test("runs at 30fps when frontmost with arcs to animate")
    func fullRateWithDestinations() {
        let schedule = GlobeAnimation.schedule(active: true, destinationCount: 3)
        #expect(!schedule.paused)
        #expect(abs(schedule.interval - 1.0 / 30.0) < 1e-9)
    }

    @Test("drops to a slow idle breath when frontmost but nothing is on the map")
    func slowWhenEmpty() {
        let schedule = GlobeAnimation.schedule(active: true, destinationCount: 0)
        #expect(!schedule.paused)
        #expect(schedule.interval > 1.0 / 30.0) // strictly slower than full rate
    }
}
