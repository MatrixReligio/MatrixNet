import AppKit
import MatrixNetModel

/// Resolves and caches process icons by PID. Resolution (a synchronous
/// `NSRunningApplication` lookup) happens only in `prewarm`, called off the
/// scroll path during the periodic refresh; cell rendering reads the cache only,
/// so scrolling never blocks the main thread. A negative cache avoids repeated
/// lookups for daemons that have no icon.
@MainActor
final class AppIconResolver {
    static let shared = AppIconResolver()

    private var cache: [Int32: NSImage?] = [:]

    /// Cached icon for a process, or `nil` if unknown/uncached. Never performs a
    /// lookup, so it is safe to call during view rendering.
    func cachedIcon(for app: AppIdentity) -> NSImage? {
        cache[app.pid].flatMap(\.self)
    }

    /// Resolves icons for any not-yet-seen PIDs. Call from the periodic refresh,
    /// not from rendering.
    func prewarm(_ apps: [AppIdentity]) {
        for app in apps where cache[app.pid] == nil {
            cache[app.pid] = NSRunningApplication(processIdentifier: app.pid)?.icon
        }
    }
}
