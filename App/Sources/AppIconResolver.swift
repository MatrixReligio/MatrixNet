import AppKit
import MatrixNetModel

/// Resolves and caches the icon for a process by PID. GUI apps yield their real
/// icon; daemons and helpers fall back to a generic symbol at the call site.
@MainActor
final class AppIconResolver {
    static let shared = AppIconResolver()

    private var cache: [Int32: NSImage] = [:]

    func icon(for app: AppIdentity) -> NSImage? {
        if let cached = cache[app.pid] { return cached }
        guard let icon = NSRunningApplication(processIdentifier: app.pid)?.icon else { return nil }
        cache[app.pid] = icon
        return icon
    }
}
