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

    /// A reused PID (same number, different process start time) must not return
    /// the prior process's path. Uses an out-of-range PID so it won't collide
    /// with the process-global cache other tests touch.
    @Test("a reused PID re-reads instead of returning the stale path")
    func pidReuseInvalidatesCache() {
        let pid: Int32 = 1_234_567
        var start: UInt64 = 1000
        var reads = 0
        let read: (Int32) -> String? = { _ in
            reads += 1
            return "/path/at/\(start)"
        }

        #expect(ProcessPathResolver.resolve(pid: pid, startTime: { _ in start }, readPath: read) == "/path/at/1000")
        #expect(reads == 1)

        // Same PID, same start time → cache hit, no re-read.
        #expect(ProcessPathResolver.resolve(pid: pid, startTime: { _ in start }, readPath: read) == "/path/at/1000")
        #expect(reads == 1)

        // PID reused: start time changed → must re-read, never the stale path.
        start = 2000
        #expect(ProcessPathResolver.resolve(pid: pid, startTime: { _ in start }, readPath: read) == "/path/at/2000")
        #expect(reads == 2)
    }
}
