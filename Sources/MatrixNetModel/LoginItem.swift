import Foundation

/// Abstracts the platform login-item service so the enable/disable logic can be
/// unit-tested with a fake, independent of the real `SMAppService`.
public protocol LoginItemManaging: Sendable {
    /// Whether the app is currently registered to launch at login.
    var isEnabled: Bool { get }
    /// Register the app as a login item.
    func enable() throws
    /// Unregister the app as a login item.
    func disable() throws
}

/// Drives a `LoginItemManaging` from a single boolean intent, surfacing failures
/// to the caller (so the UI can revert the toggle and explain).
public struct LoginItemController: Sendable {
    private let manager: LoginItemManaging

    public init(manager: LoginItemManaging) {
        self.manager = manager
    }

    public var isEnabled: Bool {
        manager.isEnabled
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try manager.enable()
        } else {
            try manager.disable()
        }
    }

    /// Applies the desired state and returns the service's *actual* resulting
    /// state. With `SMAppService` a successful register can land in
    /// `.requiresApproval` — desired `true`, actual `false` — and the caller
    /// must surface that without feeding the correction back into another
    /// `setEnabled(false)`, which would unregister the pending approval.
    public func apply(_ enabled: Bool) throws -> Bool {
        try setEnabled(enabled)
        return manager.isEnabled
    }
}

#if canImport(ServiceManagement)
    import ServiceManagement

    /// The production `LoginItemManaging` backed by `SMAppService.mainApp`. Available
    /// to a Developer ID app without a separate helper; status `.enabled` means the
    /// login item is active.
    public struct SMAppServiceLoginItem: LoginItemManaging {
        public init() {}

        public var isEnabled: Bool {
            SMAppService.mainApp.status == .enabled
        }

        public func enable() throws {
            try SMAppService.mainApp.register()
        }

        public func disable() throws {
            try SMAppService.mainApp.unregister()
        }
    }
#endif
