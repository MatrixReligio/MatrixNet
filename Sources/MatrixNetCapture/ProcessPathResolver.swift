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
enum ProcessPathResolver {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [Int32: String?] = [:]

    /// The executable path for `pid`, or `nil` if it can't be read (gone, or
    /// owned by another user). Cached by PID.
    static func path(pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[pid] { return cached }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let resolved: String? = if length > 0, let path = String(bytes: buffer.prefix(Int(length)), encoding: .utf8),
                                   !path.isEmpty {
            path
        } else {
            nil
        }
        cache[pid] = resolved
        return resolved
    }
}
