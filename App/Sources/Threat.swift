import Foundation
import MatrixNetModel
import MatrixNetThreat
import os

/// App-level access to the threat-IP list, with periodic background updates.
///
/// The newest valid list wins: a copy downloaded into Application Support
/// (refreshed roughly weekly from the project's `threatlist-latest` release)
/// takes precedence over the one bundled at build time. If neither is present no
/// address is flagged — every other feature works unchanged.
///
/// The list is purely advisory: MatrixNet labels matching remotes, it never
/// blocks. Lookups are synchronous and called from the UI; the database is
/// swapped atomically under a lock after a successful download.
///
/// Source: IPsum (https://github.com/stamparm/ipsum), public domain (Unlicense),
/// level 3 — addresses present on three or more independent blocklists.
enum Threat {
    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var database: ThreatDatabase?
        init(_ database: ThreatDatabase?) {
            self.database = database
        }

        func contains(_ address: IPAddress) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return database?.contains(address) ?? false
        }

        func replace(with database: ThreatDatabase) {
            lock.lock()
            self.database = database
            lock.unlock()
        }
    }

    private static let storage = Storage(loadBest())
    private static let log = Logger(subsystem: "com.matrixreligio.matrixnet", category: "threat")

    /// Stable URL of the auto-updated dataset (published by CI).
    private static let remoteURL = URL(
        string: "https://github.com/MatrixReligio/MatrixNet/releases/download/threatlist-latest/threatlist.dat"
    )!
    private static let lastCheckedKey = "ThreatListLastChecked"

    /// Whether the address is on the threat list.
    static func isThreat(_ address: IPAddress) -> Bool {
        storage.contains(address)
    }

    /// When the list was last checked for an update (shown in Settings).
    static var lastChecked: Date? {
        UserDefaults.standard.object(forKey: lastCheckedKey) as? Date
    }

    // MARK: - Loading

    private static var downloadedURL: URL? {
        try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MatrixNet", isDirectory: true)
            .appendingPathComponent("threatlist.dat")
    }

    /// Loads the freshest valid database: the downloaded copy if present and
    /// valid, else the bundled one.
    private static func loadBest() -> ThreatDatabase? {
        if let url = downloadedURL,
           let data = try? Data(contentsOf: url),
           ThreatUpdatePolicy.isValidDatabase(data) {
            return ThreatDatabase(data: data)
        }
        guard let url = Bundle.main.url(forResource: "threatlist", withExtension: "dat"),
              let data = try? Data(contentsOf: url) else { return nil }
        return ThreatDatabase(data: data)
    }

    // MARK: - Updating

    /// Downloads a newer dataset when the check is due, validates it, installs it
    /// atomically into Application Support and swaps it in. Safe to call on every
    /// launch — it self-throttles and fails silently (labels are non-critical).
    static func updateIfNeeded(now: Date = Date(), force: Bool = false) async {
        let defaults = UserDefaults.standard
        let lastChecked = defaults.object(forKey: lastCheckedKey) as? Date
        guard force || ThreatUpdatePolicy.shouldCheck(now: now, lastChecked: lastChecked) else { return }
        defaults.set(now, forKey: lastCheckedKey)

        guard let destination = downloadedURL else { return }
        do {
            var request = URLRequest(url: remoteURL)
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            guard ThreatUpdatePolicy.isValidDatabase(data) else {
                log.warning("Downloaded threat list failed validation; keeping current.")
                return
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
            if let fresh = ThreatDatabase(data: data) {
                storage.replace(with: fresh)
                log.info("Threat list updated (\(data.count) bytes).")
            }
        } catch {
            log.debug("Threat list update skipped: \(error.localizedDescription, privacy: .public)")
        }
    }
}
