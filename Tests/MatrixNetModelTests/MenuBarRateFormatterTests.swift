import Testing
@testable import MatrixNetModel

@Suite("MenuBarRateFormatter")
struct MenuBarRateFormatterTests {
    @Test("idle shows dashes for both directions")
    func idle() {
        #expect(MenuBarRateFormatter.compact(in: 0, out: 0) == "↓ — ↑ —")
    }

    @Test("a sub-one-byte rate renders as a dash")
    func subOne() {
        #expect(MenuBarRateFormatter.shortRate(0.4) == "—")
    }

    @Test("bytes under 1K show the B suffix with no decimal")
    func bytes() {
        #expect(MenuBarRateFormatter.shortRate(900) == "900B")
        #expect(MenuBarRateFormatter.shortRate(5) == "5B")
    }

    @Test("kilobytes under ten keep one decimal")
    func kilo() {
        #expect(MenuBarRateFormatter.shortRate(1700) == "1.7K")
    }

    @Test("megabytes scale correctly")
    func mega() {
        #expect(MenuBarRateFormatter.shortRate(1_782_579) == "1.7M")
    }

    @Test("ten or more drops the decimal to stay compact")
    func tens() {
        #expect(MenuBarRateFormatter.shortRate(15000) == "15K")
    }

    @Test("compact combines both directions")
    func compact() {
        #expect(MenuBarRateFormatter.compact(in: 1_782_579, out: 0) == "↓ 1.7M ↑ —")
    }
}
