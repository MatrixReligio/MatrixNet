import Darwin
import Testing
@testable import MatrixNetCapture

@Suite("ProcessPathResolver")
struct ProcessPathResolverTests {
    @Test("resolves the current process's own executable path")
    func ownPath() {
        let path = ProcessPathResolver.path(pid: getpid())
        #expect(path?.isEmpty == false)
    }

    @Test("an invalid pid resolves to nil")
    func invalidPid() {
        #expect(ProcessPathResolver.path(pid: -1) == nil)
        #expect(ProcessPathResolver.path(pid: 0) == nil)
    }
}
