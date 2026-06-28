/// One TLS client fingerprint observed for an app: its display name paired with
/// the JA4 string. The set of these is "which TLS stacks has this process used".
public struct AppFingerprintObservation: Sendable, Equatable {
    public let app: String
    public let ja4: String

    public init(app: String, ja4: String) {
        self.app = app
        self.ja4 = ja4
    }
}
