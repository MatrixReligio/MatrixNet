import Foundation
import Testing
@testable import MatrixNetModel

@Suite("Preferences")
struct PreferencesTests {
    private func freshDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "test." + UUID().uuidString))
    }

    @Test("defaults are sensible on a fresh store")
    func defaults() throws {
        let prefs = try Preferences(defaults: freshDefaults())
        #expect(prefs.launchAtLogin == false)
        #expect(prefs.runInBackground == false)
        #expect(prefs.threatNotificationsEnabled == false)
        #expect(prefs.historyRetentionDays == 30)
    }

    @Test("values round-trip through the store")
    func roundTrip() throws {
        let store = try freshDefaults()
        let prefs = Preferences(defaults: store)
        prefs.launchAtLogin = true
        prefs.runInBackground = true
        prefs.threatNotificationsEnabled = true
        prefs.historyRetentionDays = 7

        let reloaded = Preferences(defaults: store)
        #expect(reloaded.launchAtLogin == true)
        #expect(reloaded.runInBackground == true)
        #expect(reloaded.threatNotificationsEnabled == true)
        #expect(reloaded.historyRetentionDays == 7)
    }
}
