import Darwin
import Foundation

/// Resolves a PID to its full executable path via `proc_pidpath`, cached and
/// thread-safe.
///
/// NetworkStatistics' `processName` is capped at 32 characters (the kernel's
/// `proc_name` limit), so a long name like a system extension's bundle id
/// (`com.adguard.mac.adguard.network-extension`) arrives truncated. The path's
/// last component is the untruncated name, matching how the packet pipeline
/// resolves process names.
///
/// The cache is keyed by PID but **validated by process start time**: macOS
/// reuses PIDs, so a bare PID cache would keep serving a dead process's path to
/// whatever later inherits its PID, mislabeling that traffic. Each lookup
/// confirms the cached start time still matches before trusting the entry.
enum ProcessPathResolver {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [Int32: (start: UInt64, path: String?)] = [:]

    /// The executable path for `pid`, or `nil` if it can't be read (gone, or
    /// owned by another user). Cached by PID, revalidated by start time.
    static func path(pid: Int32) -> String? {
        resolve(pid: pid, startTime: startTime(of:), readPath: readPath(pid:))
    }

    /// Testable core. A cache hit requires the process start time to match, so a
    /// reused PID (same number, new process) re-reads rather than returning the
    /// previous process's path.
    static func resolve(
        pid: Int32,
        startTime: (Int32) -> UInt64,
        readPath: (Int32) -> String?
    ) -> String? {
        guard pid > 0 else { return nil }
        let start = startTime(pid)
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[pid], cached.start == start { return cached.path }
        let resolved = readPath(pid)
        cache[pid] = (start, resolved)
        return resolved
    }

    /// The process's start time in seconds since the epoch via libproc, or 0 when
    /// it can't be read (the process is gone or not inspectable). 0 still works as
    /// a cache key — a real process that later reuses the PID will report a
    /// non-zero start time and miss the stale entry.
    static func startTime(of pid: Int32) -> UInt64 {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size)
        }
        guard read == size else { return 0 }
        return UInt64(info.pbi_start_tvsec)
    }

    private static func readPath(pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0, let path = String(bytes: buffer.prefix(Int(length)), encoding: .utf8), !path.isEmpty
        else {
            return nil
        }
        return path
    }
}
