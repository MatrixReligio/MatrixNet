import Testing
@testable import MatrixNetModel

private struct LoginItemBoom: Error {}

private final class FakeLoginItem: LoginItemManaging, @unchecked Sendable {
    var enabled = false
    var enableCount = 0
    var disableCount = 0
    var throwOnEnable = false

    var isEnabled: Bool {
        enabled
    }

    func enable() throws {
        if throwOnEnable { throw LoginItemBoom() }
        enableCount += 1
        enabled = true
    }

    func disable() throws {
        disableCount += 1
        enabled = false
    }
}

@Suite("LoginItemController")
struct LoginItemTests {
    @Test("enabling registers and reflects the new state")
    func enable() throws {
        let fake = FakeLoginItem()
        let controller = LoginItemController(manager: fake)
        try controller.setEnabled(true)
        #expect(fake.enableCount == 1)
        #expect(controller.isEnabled == true)
    }

    @Test("disabling unregisters")
    func disable() throws {
        let fake = FakeLoginItem()
        fake.enabled = true
        let controller = LoginItemController(manager: fake)
        try controller.setEnabled(false)
        #expect(fake.disableCount == 1)
        #expect(controller.isEnabled == false)
    }

    @Test("an enable failure propagates to the caller")
    func error() {
        let fake = FakeLoginItem()
        fake.throwOnEnable = true
        let controller = LoginItemController(manager: fake)
        #expect(throws: (any Error).self) { try controller.setEnabled(true) }
    }
}
