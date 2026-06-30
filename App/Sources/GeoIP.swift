import Foundation
import MatrixNetGeoIP
import MatrixNetModel
import os

/// App-level access to the GeoIP database, with periodic background updates.
///
/// The newest valid database wins: a copy downloaded into Application Support
/// (refreshed roughly weekly from the project's `geoip-latest` release) takes
/// precedence over the one bundled at build time. If neither is present the app
/// simply shows no flags — address-scope classification still works.
///
/// Lookups are synchronous and called from the UI; the database is swapped
/// atomically under a lock after a successful download, so reads never tear.
enum GeoIP {
    /// Thread-safe holder for the active database. Using an immutable `let` of a
    /// locked class avoids a `nonisolated(unsafe)` mutable static.
    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var database: GeoIPDatabase?
        init(_ database: GeoIPDatabase?) {
            self.database = database
        }

        func country(for address: IPAddress) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return database?.country(for: address)
        }

        func replace(with database: GeoIPDatabase) {
            lock.lock()
            self.database = database
            lock.unlock()
        }

        /// Whether a usable (non-empty) database is loaded. An absent or empty
        /// database means lookups return nil, so the updater treats it as "none"
        /// and downloads one immediately instead of waiting for the weekly window.
        var hasDatabase: Bool {
            lock.lock()
            defer { lock.unlock() }
            guard let database else { return false }
            return !database.isEmpty
        }
    }

    private static let storage = Storage(loadBest())
    private static let log = Logger(subsystem: "com.matrixreligio.matrixnet", category: "geoip")

    /// Stable URL of the auto-updated dataset (published monthly by CI).
    private static let remoteURL = URL(
        string: "https://github.com/MatrixReligio/MatrixNet/releases/download/geoip-latest/geoip.dat"
    )!
    private static let lastCheckedKey = "GeoIPLastChecked"

    static func country(for address: IPAddress) -> String? {
        // Loopback/private/link-local addresses have no geographic country; the
        // dataset marks them "ZZ", so skip the lookup entirely for non-global IPs.
        guard address.scope == .global else { return nil }
        return storage.country(for: address)
    }

    /// Flag emoji for an address's country, or `nil` if unknown.
    static func flag(for address: IPAddress) -> String? {
        country(for: address).flatMap(GeoIPDatabase.flag)
    }

    /// When the dataset was last checked for an update (shown in Settings).
    static var lastChecked: Date? {
        UserDefaults.standard.object(forKey: lastCheckedKey) as? Date
    }

    // MARK: - Loading

    private static var downloadedURL: URL? {
        try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MatrixNet", isDirectory: true)
            .appendingPathComponent("geoip.dat")
    }

    /// Loads the freshest valid database: the downloaded copy if present and
    /// valid, else the bundled one.
    private static func loadBest() -> GeoIPDatabase? {
        if let url = downloadedURL,
           let data = try? Data(contentsOf: url),
           GeoIPUpdatePolicy.isValidDatabase(data) {
            return GeoIPDatabase(data: data)
        }
        guard let url = Bundle.main.url(forResource: "geoip", withExtension: "dat"),
              let data = try? Data(contentsOf: url) else { return nil }
        return GeoIPDatabase(data: data)
    }

    // MARK: - Updating

    /// Downloads a newer dataset when the check is due, validates it, installs it
    /// atomically into Application Support and swaps it in. Safe to call on every
    /// launch — it self-throttles and fails silently (flags are non-critical).
    static func updateIfNeeded(now: Date = Date(), force: Bool = false) async {
        let defaults = UserDefaults.standard
        let lastChecked = defaults.object(forKey: lastCheckedKey) as? Date
        let hasDatabase = storage.hasDatabase
        guard GeoIPUpdatePolicy.shouldDownload(
            hasDatabase: hasDatabase, force: force, now: now, lastChecked: lastChecked
        ) else { return }
        guard let destination = downloadedURL else { return }

        let succeeded = await downloadAndInstall(to: destination)
        // Throttle the next check only when it won't strand an empty install:
        // on success always, on failure only if a usable database already exists.
        if GeoIPUpdatePolicy.shouldRecordCheck(succeeded: succeeded, hasDatabase: hasDatabase) {
            defaults.set(now, forKey: lastCheckedKey)
        }
    }

    /// Downloads, validates, installs, and hot-swaps the database. Returns whether
    /// a fresh database was successfully installed.
    private static func downloadAndInstall(to destination: URL) async -> Bool {
        do {
            var request = URLRequest(url: remoteURL)
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            guard GeoIPUpdatePolicy.isValidDatabase(data) else {
                log.warning("Downloaded GeoIP database failed validation; keeping current.")
                return false
            }
            guard await DataAssetSignature.isValid(
                data: data, signatureURL: remoteURL.appendingPathExtension("edsig")
            ) else {
                log.warning("Downloaded GeoIP database failed signature verification; keeping current.")
                return false
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
            guard let fresh = GeoIPDatabase(data: data) else { return false }
            storage.replace(with: fresh)
            log.info("GeoIP database updated (\(data.count) bytes).")
            return true
        } catch {
            log.debug("GeoIP update skipped: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
