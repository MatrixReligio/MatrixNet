import AppKit
import Foundation
import MatrixNetCapture
import MatrixNetDissection
import MatrixNetGeoIP
import MatrixNetModel
import MatrixNetStore
import Observation
import WidgetKit

/// Top-level observable state for the connection monitor. Bridges the passive,
/// actor-isolated capture pipeline to SwiftUI on the main actor: it drains the
/// `NetworkStatisticsMonitor` event stream into a `ConnectionAggregator` and
/// periodically publishes a sorted snapshot for the views to render.
@MainActor
@Observable
public final class AppModel {
    /// The current connections, sorted for display (most recently active first).
    public private(set) var connections: [Connection] = []
    /// Whether passive monitoring is active.
    public private(set) var isMonitoring = false
    /// Set when the NetworkStatistics framework is unavailable on this system.
    public private(set) var monitoringUnavailable = false

    /// Session-cumulative bytes received since monitoring started (monotonic).
    public private(set) var sessionBytesIn: UInt64 = 0
    /// Session-cumulative bytes sent since monitoring started.
    public private(set) var sessionBytesOut: UInt64 = 0
    /// Current inbound throughput in bytes per second.
    public private(set) var throughputIn: Double = 0
    /// Current outbound throughput in bytes per second.
    public private(set) var throughputOut: Double = 0

    /// Session-cumulative per-app traffic, sorted by total bytes (most first).
    /// The Overview and widget "top talkers" read this rather than summing the
    /// live snapshot's instantaneous per-connection bytes (which are ~0 for the
    /// many idle keep-alive sockets, and lost when short-lived flows close).
    public private(set) var topApps: [AppTraffic] = []

    /// Number of currently active connections whose remote IP is on the threat
    /// list. Surfaced in the app and widget; advisory only (never blocks).
    public private(set) var threatCount: Int = 0

    /// Recent throughput samples (≈ last minute) for the Overview live chart.
    public private(set) var throughputHistory = ThroughputHistory(capacity: 60)
    /// Distinct processes with an active connection.
    public private(set) var activeAppCount: Int = 0
    /// Distinct known destination countries among active connections.
    public private(set) var countriesReached: Int = 0
    /// Fraction (0...1) of active connections routed through a proxy.
    public private(set) var proxyShare: Double = 0
    /// Active-connection share by application protocol (most common first).
    public private(set) var protocolMix: [ProtocolShare] = []
    /// Active connections grouped by destination country (most connections first).
    public private(set) var destinationCountries: [CountryActivity] = []
    /// Countries that currently host at least one threat-flagged active remote.
    public private(set) var threatCountries: Set<String> = []
    /// Known IP→hostname map (reverse DNS + DNS-enriched), keyed by the IP's
    /// string form, for views that only have the textual address (e.g. Packets).
    public private(set) var resolvedHostnames: [String: String] = [:]
    /// The busiest apps, enriched with live connection count, country flag, and
    /// threat/tunnel markers for the Overview "Top Talkers" list.
    private(set) var topTalkers: [TopTalker] = []

    /// Posts threat-connection notifications; set by the app delegate at launch.
    var threatNotifier: ThreatNotifier?
    /// Posts new-destination notifications; set by the app delegate at launch.
    var newDestinationNotifier: NewDestinationNotifier?
    let preferences = Preferences(defaults: SharedMetricsStore.sharedDefaults ?? .standard)

    /// Recovers the real country of proxied (fake-IP) flows by resolving their
    /// domain via DoH. Only invoked for proxied flows whose country is otherwise
    /// unknown, and only when the preference is on — so a machine with no proxy
    /// stays fully passive. Results land in `proxyCountryByHost` (host → ISO code).
    private let proxyGeo = ActiveGeoResolver(
        enabled: true,
        resolver: DoHResolver(),
        lookupCountry: { GeoIP.country(for: $0) }
    )
    private var proxyCountryByHost: [String: String] = [:]

    private var monitor: NetworkStatisticsMonitor?
    /// Shared with the packet pipeline so captured packets are attributed to the
    /// same connections (the aggregator is built for both sources).
    let aggregator = ConnectionAggregator()
    private let resolver = HostnameResolver()
    /// All three stores MUST share one container; separate containers at the
    /// default URL make SwiftData migrate the store to the last-opened schema and
    /// drop the other models' tables (lost history, broke usage).
    private let historyStore: HistoryStore?
    // Accessed by the usage-flush logic in AppModel+Usage.swift.
    let usageStore: UsageStore?
    // One baseline per usage source: the two sources observe the same wire
    // traffic with different counters, so each must be diffed against itself
    // (see UsageAccumulator.sourcedDeltas) or a capture start/stop would
    // double-count or freeze keys.
    var lastUsageSeenPacket: [String: UsageTotals] = [:]
    var lastUsageSeenNStat: [String: UsageTotals] = [:]
    var lastUsageFlush = Date.distantPast
    var lastCompactedHour: Date?
    private let destinationBaselineStore: DestinationBaselineStore?
    private var knownDestinations: [String: AppBaseline] = [:]
    private let fingerprintStore: FingerprintStore?
    /// Per-app TLS client fingerprints, loaded from the store and refreshed on
    /// each flush. Read by the connection inspector. Populated only while packet
    /// capture is active (a ClientHello is required to compute JA4).
    private var fingerprintsByApp: [String: [StoredFingerprint]] = [:]
    private var lastFingerprintFlush = Date.distantPast
    /// Live per-(app, destination) network quality, refreshed from the aggregator
    /// each poll while capturing. Keyed by "app\u{1F}address". Not persisted —
    /// quality is a live diagnostic, not history. Read by the connection inspector.
    private var qualityByKey: [String: FlowQuality] = [:]
    private var pumpTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var lastMetricsWrite = Date.distantPast
    private var lastWidgetReload = Date.distantPast
    // The widget is a periodic glance, not a live monitor: refresh it at most once
    // a minute while the app is foreground (budget-exempt reloads), and persist the
    // metrics file at most every 20 min in the background — roughly the widget's
    // ~30-min background refresh cadence, with margin — so the disk isn't written
    // on every ~1s tick for snapshots no one reads.
    private let widgetReloadGate = WidgetReloadGate(minInterval: 60, heartbeatInterval: 1200)
    private var lastHistoryWrite = Date.distantPast
    private var lastRateSampleAt = Date.distantPast
    private var lastRateBytesIn: UInt64 = 0
    private var lastRateBytesOut: UInt64 = 0

    public init() {
        let container = try? SharedModelContainer.make()
        historyStore = container.map(HistoryStore.init(container:))
        usageStore = container.map(UsageStore.init(container:))
        destinationBaselineStore = container.map(DestinationBaselineStore.init(container:))
        fingerprintStore = container.map(FingerprintStore.init(container:))
        performUsageLaunchMaintenance()
        knownDestinations = (try? destinationBaselineStore?.load()) ?? [:]
        fingerprintsByApp = (try? fingerprintStore?.load()) ?? [:]
    }

    /// The total number of currently active (not closed) connections.
    public var activeCount: Int {
        connections.lazy.count(where: { $0.state == .active })
    }

    /// Starts passive monitoring. No privileges or user approval required.
    public func start() {
        guard !isMonitoring else { return }
        guard let monitor = NetworkStatisticsMonitor() else {
            monitoringUnavailable = true
            return
        }
        self.monitor = monitor
        isMonitoring = true

        // Clear any state from a previous session before the new stream begins
        // (the monitor reassigns ids on restart, so stale entries would linger).
        sessionBytesIn = 0
        sessionBytesOut = 0
        throughputIn = 0
        throughputOut = 0
        lastRateSampleAt = .distantPast
        lastRateBytesIn = 0
        lastRateBytesOut = 0
        // The aggregator's usage totals are reset alongside the new stream, so
        // the delta baseline must restart from empty too. Defer the first usage
        // flush a full interval so it can't read a snapshot before the async
        // `aggregator.reset()` lands and double-count stale totals.
        lastUsageSeenPacket.removeAll()
        lastUsageSeenNStat.removeAll()
        lastUsageFlush = Date()
        lastCompactedHour = UsageBucketing.hourStart(of: Date(), calendar: .current)

        let stream = monitor.start()
        let aggregator = aggregator
        let resolver = resolver
        pumpTask = Task {
            await aggregator.reset()
            await aggregator.consume(stream)
        }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot = await aggregator.snapshot()
                let session = await aggregator.sessionTotals()
                let apps = await aggregator.appTraffic()
                await resolver.resolveIfNeeded(snapshot.map(\.fiveTuple.destination.address))
                let reverseDNS = await resolver.snapshot()
                // SNI/DNS observed names are exact (the host the app requested),
                // so they win over reverse-DNS PTR records (often CDN wildcards).
                let observed = await aggregator.hostnameSnapshot()
                let hostnames = reverseDNS.merging(observed) { _, exact in exact }
                // Keep proxy/tunnel state current so the proxy share reflects a
                // VPN/proxy toggled on or off mid-session (cheap SC reads).
                ProxyInfo.refresh()
                self?.publish(snapshot, hostnames: hostnames, session: session, apps: apps)
                await self?.flushUsage(now: Date())
                await self?.flushFingerprints(now: Date())
                await self?.refreshQuality()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Stops monitoring and tears down the pipeline.
    public func stop() {
        // Persist the final sub-interval of usage before teardown: flushUsage is
        // throttled to 30s, so without this a pause loses up to the last 30s. The
        // aggregator keeps its totals until the next start()'s reset, so this Task
        // reads valid data even though teardown proceeds.
        Task { await flushUsageNow() }
        monitor?.stop()
        monitor = nil
        pumpTask?.cancel()
        refreshTask?.cancel()
        pumpTask = nil
        refreshTask = nil
        isMonitoring = false
        throughputIn = 0
        throughputOut = 0
    }

    private func publish(
        _ snapshot: [Connection],
        hostnames: [IPAddress: String],
        session: (bytesIn: UInt64, bytesOut: UInt64),
        apps: [AppTraffic]
    ) {
        // Every published property below is reassigned each ~1s tick. @Observable
        // fires on assignment without comparing, so an *identical* value still
        // invalidates every view that read it — a full re-render/row-height
        // re-measure once a second even when nothing changed. Gate each assignment
        // on inequality (as resolvedHostnames already does) so an idle app costs
        // nothing. The derived scalars/sets change only when the connection set or
        // countries change (not on every byte tick), so this eliminates most idle
        // re-renders of the Overview/Map; connections/topApps still update whenever
        // bytes actually move.
        let sortedApps = apps.sorted { $0.bytes > $1.bytes }
        if topApps != sortedApps { topApps = sortedApps }
        // Resolve icons here (off the scroll path); cells then read the cache.
        AppIconResolver.shared.prewarm(snapshot.map(\.app))
        let enriched = snapshot
            .map { connection in
                guard connection.remoteHostname == nil,
                      let hostname = hostnames[connection.fiveTuple.destination.address]
                else {
                    return connection
                }
                var enriched = connection
                enriched.remoteHostname = hostname
                return enriched
            }
            .sorted { lhs, rhs in
                if (lhs.state == .active) != (rhs.state == .active) {
                    return lhs.state == .active // active connections first
                }
                return lhs.lastActivityAt > rhs.lastActivityAt
            }
        if connections != enriched { connections = enriched }
        let threats = enriched.filter {
            $0.state == .active && Threat.isThreat($0.fiveTuple.destination.address)
        }
        if threatCount != threats.count { threatCount = threats.count }
        threatNotifier?.evaluate(
            threats.map {
                ThreatNotifier.Hit(
                    app: $0.app.displayName,
                    ip: $0.fiveTuple.destination.address.description,
                    host: $0.remoteHostname
                )
            },
            enabled: preferences.threatNotificationsEnabled
        )
        detectNewDestinations(now: Date())

        refreshOverview(connections: enriched, threats: threats, hostnames: hostnames)

        updateThroughput(session: session)
        publishWidgetMetrics()
        recordHistory()
    }

    /// Builds the enriched "Top Talkers" rows from the busiest apps and their
    /// current active connections (country flag, threat hit, tunnel role).
    private func makeTopTalkers(connections: [Connection]) -> [TopTalker] {
        let activeByApp = Dictionary(grouping: connections.filter { $0.state == .active }, by: \.app)
        return topApps.prefix(8).map { entry in
            let conns = activeByApp[entry.app] ?? []
            let flag = conns.lazy.compactMap { self.country(for: $0).flatMap(GeoIPDatabase.flag) }.first
            let isThreat = conns.contains { Threat.isThreat($0.fiveTuple.destination.address) }
            return TopTalker(
                app: entry.app,
                bytes: entry.bytes,
                connectionCount: conns.count,
                flag: flag,
                isThreat: isThreat,
                isTunnel: ProxyInfo.isTunnel(entry.app.displayName)
            )
        }
    }

    /// Updates the session totals and derives the throughput rate from the byte
    /// delta since the last sample. Driven by the ~1s refresh tick.
    private func updateThroughput(session: (bytesIn: UInt64, bytesOut: UInt64)) {
        let now = Date()
        sessionBytesIn = session.bytesIn
        sessionBytesOut = session.bytesOut
        let elapsed = now.timeIntervalSince(lastRateSampleAt)
        if lastRateSampleAt != .distantPast, elapsed > 0.1 {
            let deltaIn = session.bytesIn >= lastRateBytesIn ? session.bytesIn - lastRateBytesIn : 0
            let deltaOut = session.bytesOut >= lastRateBytesOut ? session.bytesOut - lastRateBytesOut : 0
            throughputIn = Double(deltaIn) / elapsed
            throughputOut = Double(deltaOut) / elapsed
        }
        lastRateSampleAt = now
        lastRateBytesIn = session.bytesIn
        lastRateBytesOut = session.bytesOut
        throughputHistory.append(ThroughputSample(time: now, inRate: throughputIn, outRate: throughputOut))
    }

    /// The most recent persisted connection-history records.
    public func recentHistory(limit: Int = 200) -> [ConnectionHistoryRecord] {
        (try? historyStore?.recent(limit: limit)) ?? []
    }

    /// Persists the current connections to history (throttled).
    private func recordHistory() {
        let now = Date()
        guard let historyStore, now.timeIntervalSince(lastHistoryWrite) >= 5 else { return }
        lastHistoryWrite = now

        let summaries = connections.map { connection in
            ConnectionSummary(
                id: connection.id,
                appName: connection.app.displayName,
                remoteHost: connection.remoteHostname ?? connection.fiveTuple.destination.address.description,
                proto: connection.fiveTuple.proto.displayName,
                bytesIn: Int(min(connection.bytesIn, UInt64(Int.max))),
                bytesOut: Int(min(connection.bytesOut, UInt64(Int.max))),
                at: connection.lastActivityAt
            )
        }
        try? historyStore.record(summaries)
    }

    /// Classifies each active connection's destination country against the
    /// per-app baseline, learning new destinations silently during an app's first
    /// 15 minutes and alerting (when enabled) on genuinely new countries after.
    private func detectNewDestinations(now: Date) {
        let learningWindow: TimeInterval = 900
        let alertsEnabled = preferences.newDestinationAlertsEnabled
        for connection in connections where connection.state == .active {
            guard let country = country(for: connection) else { continue }
            let app = connection.app.displayName
            let baseline = knownDestinations[app]
            let verdict = NewDestinationDetector.classify(
                country: country,
                knownCountries: baseline?.countries ?? [],
                appFirstSeen: baseline?.firstSeen,
                now: now,
                learningWindow: learningWindow
            )
            switch verdict {
            case .known:
                continue
            case .learning:
                recordDestination(app: app, country: country, now: now)
            case .alert:
                // Only commit to the baseline once the alert is actually
                // surfaced; a rate-limited destination stays unrecorded so the
                // next tick retries it (otherwise it would be silently promoted
                // to "known" and never alert). When alerts are off (or no
                // notifier), record unconditionally so the baseline still grows.
                guard alertsEnabled, let notifier = newDestinationNotifier else {
                    recordDestination(app: app, country: country, now: now)
                    continue
                }
                let region = Locale.current.localizedString(forRegionCode: country) ?? country
                if notifier.notify(app: app, country: region, host: connection.remoteHostname, now: now) {
                    recordDestination(app: app, country: country, now: now)
                }
            }
        }
    }

    /// Adds an (app, country) to the in-memory baseline and the persistent store.
    private func recordDestination(app: String, country: String, now: Date) {
        if var existing = knownDestinations[app] {
            existing.countries.insert(country)
            knownDestinations[app] = existing
        } else {
            knownDestinations[app] = AppBaseline(countries: [country], firstSeen: now)
        }
        try? destinationBaselineStore?.record(app: app, country: country, at: now)
    }

    /// Hourly usage rows for the Usage tab over the given reporting period.
    public func usageRows(for period: UsagePeriod) -> [UsageRow] {
        (try? usageStore?.fetch(range: period.range(now: Date(), calendar: .current))) ?? []
    }

    /// Publishes a compact metrics snapshot to the shared App Group container and
    /// asks WidgetKit to reload the widget's timeline. Throttled so the widget
    /// stays fresh without thrashing the disk or the reload budget.
    private func publishWidgetMetrics() {
        let now = Date()
        guard let url = SharedMetricsStore.defaultURL() else { return }
        // The widget only reads this file when its timeline refreshes (≈ every 10s
        // while the app is the foreground app, ≈ every 30 min in the background).
        // Writing on every ~1s tick just wears the disk for snapshots nobody reads,
        // so only write right before a reload, or on the slow background heartbeat.
        let decision = widgetReloadGate.decide(
            isForeground: NSApp.isActive,
            now: now,
            lastReload: lastWidgetReload,
            lastWrite: lastMetricsWrite
        )
        guard decision.write else { return }
        lastMetricsWrite = now

        let widgetApps = topApps.prefix(5).map { MetricsSnapshot.TopApp(name: $0.app.displayName, bytes: $0.bytes) }

        let snapshot = MetricsSnapshot(
            activeConnections: activeCount,
            totalConnections: connections.count,
            bytesIn: sessionBytesIn,
            bytesOut: sessionBytesOut,
            throughputIn: throughputIn,
            throughputOut: throughputOut,
            topApps: Array(widgetApps),
            threatCount: threatCount,
            updatedAt: now
        )
        SharedMetricsStore.write(snapshot, to: url)

        // Nudge WidgetKit to pick up the fresh snapshot — but ONLY while the app
        // is in the foreground, where app-initiated reloads are exempt from the
        // daily refresh budget. Reloading while backgrounded (as earlier versions
        // did on every write) burns the ~40–70/day budget within minutes and then
        // freezes the widget for the rest of the window. While backgrounded we
        // stay silent and let the widget's `.after` policy age it within budget.
        if decision.reload {
            lastWidgetReload = now
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

/// A busiest-app row for the Overview, enriched from the app's live connections.
struct TopTalker: Identifiable, Equatable {
    let app: AppIdentity
    let bytes: UInt64
    let connectionCount: Int
    let flag: String?
    let isThreat: Bool
    let isTunnel: Bool

    var id: AppIdentity.ID {
        app.id
    }
}

// MARK: - TLS client fingerprints (JA4)

extension AppModel {
    /// The TLS client fingerprints observed for an app, most recently seen first.
    /// Empty until packet capture has seen a ClientHello from the app.
    public func fingerprints(for app: String) -> [StoredFingerprint] {
        (fingerprintsByApp[app] ?? []).sorted { $0.lastSeen > $1.lastSeen }
    }

    /// Persists newly observed TLS client fingerprints and refreshes the in-memory
    /// map the inspector reads. Throttled to ≈ 30s, like usage. The human label is
    /// derived here (the store layer has no JA4 knowledge).
    func flushFingerprints(now: Date) async {
        guard let fingerprintStore, now.timeIntervalSince(lastFingerprintFlush) >= 30 else { return }
        lastFingerprintFlush = now
        let observations = await aggregator.fingerprintSnapshot()
        guard !observations.isEmpty else { return }
        for observation in observations {
            let label = JA4Identifier.identify(observation.ja4)?.name
            try? fingerprintStore.record(
                app: observation.app,
                ja4: observation.ja4,
                label: label,
                transport: "tcp",
                at: now
            )
        }
        fingerprintsByApp = (try? fingerprintStore.load()) ?? fingerprintsByApp
    }
}

// MARK: - Network quality

extension AppModel {
    /// Refreshes the live quality map from the aggregator (cheap; no persistence).
    func refreshQuality() async {
        let snapshot = await aggregator.qualitySnapshot()
        var map: [String: FlowQuality] = [:]
        for item in snapshot {
            map["\(item.app)\u{1F}\(item.address.description)"] = item.quality
        }
        qualityByKey = map
    }

    /// The measured network quality for a connection's (app, destination), if any
    /// has been observed since capture started.
    public func quality(for connection: Connection) -> FlowQuality? {
        qualityByKey["\(connection.app.displayName)\u{1F}\(connection.fiveTuple.destination.address.description)"]
    }
}

// MARK: - DNS privacy posture

public extension AppModel {
    /// The DNS transport this connection represents (plaintext / DoT / DoQ / DoH /
    /// local discovery / not-DNS). Derived purely from the 5-tuple and observed
    /// hostname — works during ordinary monitoring, no packet capture required.
    func dnsTransport(for connection: Connection) -> DNSTransport {
        DNSEncryptionClassifier.classify(
            proto: connection.fiveTuple.proto,
            port: connection.fiveTuple.destination.port,
            hostname: connection.remoteHostname
        )
    }

    /// The aggregate DNS posture for an app across its current connections.
    func dnsPosture(for app: String) -> AppDNSPosture {
        let transports = connections
            .filter { $0.app.displayName == app }
            .map { dnsTransport(for: $0) }
            .filter(\.isDNS)
        return AppDNSPosture(app: app, transports: Set(transports))
    }
}

// MARK: - Activity timeline

public extension AppModel {
    /// A per-app activity timeline over `period`, built from the persisted hourly
    /// usage buckets — hourly cells for Today, daily cells for multi-day windows.
    /// Works without packet capture (reuses the Usage store).
    func activityTimeline(period: UsagePeriod, now: Date = Date()) -> ActivityTimeline {
        let calendar = Calendar.current
        let (start, end) = period.range(now: now, calendar: calendar)
        let rows = usageRows(for: period)
        let hourly = period.trendGranularity == .hour
        let step: TimeInterval = hourly ? 3600 : 86400
        let anchor = hourly
            ? UsageBucketing.hourStart(of: start, calendar: calendar)
            : calendar.startOfDay(for: start)
        var hours: [Date] = []
        var cursor = anchor
        while cursor < end {
            hours.append(cursor)
            cursor = cursor.addingTimeInterval(step)
        }
        return ActivityTimelineBuilder.build(rows: rows, hours: hours)
    }
}

// MARK: - Proxy-aware geolocation

extension AppModel {
    /// A connection's destination country, proxy-aware. When a proxy/tunnel is
    /// active for the destination the kernel IP is a synthetic fake-IP (or the
    /// proxy's exit node) and must not be geolocated; use the DoH-resolved country
    /// of the real domain instead (filled asynchronously into `proxyCountryByHost`).
    /// With no proxy the IP is a real address and is geolocated normally.
    func country(for connection: Connection) -> String? {
        let destination = connection.fiveTuple.destination
        if ProxyInfo.routesThroughProxy(destination) {
            return connection.remoteHostname.flatMap { proxyCountryByHost[$0] }
        }
        return GeoIP.country(for: destination.address)
    }

    /// Destination-IP → ISO country map for the connection set, computed with the
    /// proxy-aware rule above so fake-IP destinations are never mislabelled.
    func proxyAwareCountryMap(_ connections: [Connection]) -> [IPAddress: String] {
        var map: [IPAddress: String] = [:]
        for connection in connections {
            if let code = country(for: connection) {
                map[connection.fiveTuple.destination.address] = code
            }
        }
        return map
    }

    /// Kicks off DoH resolution for proxied flows whose country isn't cached yet,
    /// when the preference is on. The next metrics pass reads the filled cache.
    func resolveProxyCountries(_ connections: [Connection]) {
        guard preferences.proxyGeoResolutionEnabled else { return }
        let hosts = Set(connections.compactMap { connection -> String? in
            guard ProxyInfo.routesThroughProxy(connection.fiveTuple.destination),
                  let host = connection.remoteHostname,
                  proxyCountryByHost[host] == nil else { return nil }
            return host
        })
        guard !hosts.isEmpty else { return }
        Task { [weak self, proxyGeo] in
            for host in hosts {
                if let code = await proxyGeo.country(forProxiedDomain: host) {
                    self?.proxyCountryByHost[host] = code
                }
            }
        }
    }

    /// Recomputes the Overview / Top-Talkers metrics from the latest snapshot:
    /// proxy-aware geolocation, byte-weighted proxy share, and the IP→hostname map.
    func refreshOverview(connections: [Connection], threats: [Connection], hostnames: [IPAddress: String]) {
        // Same diff-gating rationale as publish(): these derived values are
        // recomputed every tick but change rarely, so only publish real changes.
        let newActiveAppCount = OverviewStats.activeAppCount(connections)
        if activeAppCount != newActiveAppCount { activeAppCount = newActiveAppCount }
        let ipCountry = proxyAwareCountryMap(connections)
        let newCountriesReached = OverviewStats.countriesReached(connections) { ipCountry[$0] }
        if countriesReached != newCountriesReached { countriesReached = newCountriesReached }
        let newProxyShare = OverviewStats.proxyShare(
            connections,
            isRelay: { ProxyInfo.isTunnel($0.app.displayName) },
            routesThroughProxy: { ProxyInfo.routesThroughProxy($0) }
        )
        if proxyShare != newProxyShare { proxyShare = newProxyShare }
        let newProtocolMix = OverviewStats.protocolMix(connections)
        if protocolMix != newProtocolMix { protocolMix = newProtocolMix }
        let newDestinationCountries = OverviewStats.destinationCountries(connections) { ipCountry[$0] }
        if destinationCountries != newDestinationCountries { destinationCountries = newDestinationCountries }
        let newThreatCountries = Set(threats.compactMap { country(for: $0) })
        if threatCountries != newThreatCountries { threatCountries = newThreatCountries }
        resolveProxyCountries(connections)
        var nameMap: [String: String] = [:]
        for (ip, name) in hostnames {
            nameMap[ip.description] = name
        }
        for connection in connections {
            if let host = connection.remoteHostname {
                nameMap[connection.fiveTuple.destination.address.description] = host
            }
        }
        // Only publish when the map actually changed. This is reassigned every
        // ~1s tick, and any view that reads it (e.g. the Packets table's summary
        // column) is invalidated on every assignment — even an identical one —
        // forcing a full re-render/row-height re-measure. Hostnames change rarely
        // (only when a new lookup lands), so gating this removes a once-a-second
        // table-wide invalidation.
        if resolvedHostnames != nameMap {
            resolvedHostnames = nameMap
        }
        let newTopTalkers = makeTopTalkers(connections: connections)
        if topTalkers != newTopTalkers { topTalkers = newTopTalkers }
    }
}
