import Testing
@testable import MatrixNetModel

@Suite("AppIdentity")
struct AppIdentityTests {
    @Test("uses an explicit display name when provided")
    func explicitDisplayName() {
        let identity = AppIdentity(pid: 42, displayName: "Safari", executablePath: "/Applications/Safari.app/x")
        #expect(identity.displayName == "Safari")
    }

    @Test("derives display name from the executable file name")
    func derivesFromExecutable() {
        let identity = AppIdentity(pid: 7, executablePath: "/usr/sbin/mDNSResponder")
        #expect(identity.displayName == "mDNSResponder")
    }

    @Test("falls back to a PID placeholder when nothing else is known")
    func fallsBackToPID() {
        let identity = AppIdentity(pid: 1234)
        #expect(identity.displayName == "PID 1234")
    }

    @Test("treats an empty display name as missing")
    func emptyDisplayNameIsDerived() {
        let identity = AppIdentity(pid: 9, displayName: "", executablePath: "/bin/curl")
        #expect(identity.displayName == "curl")
    }

    @Test("identity is keyed by pid")
    func identifiableByPID() {
        #expect(AppIdentity(pid: 100).id == 100)
    }
}
