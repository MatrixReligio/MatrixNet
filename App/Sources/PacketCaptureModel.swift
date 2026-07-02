import Darwin
import Foundation
import MatrixNetCapture
import MatrixNetDissection
import MatrixNetModel
import MatrixNetXPC
import Observation
import ServiceManagement

/// A dissected packet ready for display in the packet analyzer.
struct PacketRow: Identifiable {
    let id: UInt64
    let timestamp: Date
    let processName: String
    let pid: Int32
    let direction: TrafficDirection
    let summary: String
    let protocolPath: [String]
    /// The captured bytes and their link framing, kept so the detail view can
    /// re-dissect a *single* selected packet into a full field tree on demand.
    /// The live stream dissects lightly (no field tree) for the list, which is the
    /// expensive part to build per packet — see `didCapture`.
    let bytes: [UInt8]
    let linkType: LinkLayerType

    var highestProtocol: String {
        protocolPath.last ?? "?"
    }
}

/// Drives the privileged capture helper: registration via `SMAppService`, the XPC
/// connection, and turning streamed `WirePacket`s into dissected `PacketRow`s.
/// Entirely opt-in — the connection monitor works without any of this.
@MainActor
@Observable
final class PacketCaptureModel: NSObject, CaptureClient, @unchecked Sendable {
    enum HelperState: Equatable {
        case notRegistered
        case requiresApproval
        case enabled
    }

    private(set) var helperState: HelperState = .notRegistered
    private(set) var isCapturing = false
    private(set) var lastError: String?
    private(set) var packets: [PacketRow] = []

    /// The connection aggregator captured packets are attributed to (set at
    /// launch). Lets the connections table and top talkers show real per-flow
    /// bytes while capturing — even traffic a proxy hides from NetworkStatistics.
    var attribution: ConnectionAggregator?

    private let daemon = SMAppService.daemon(plistName: CaptureXPC.helperPlistName)
    private var connection: NSXPCConnection?
    private var nextID: UInt64 = 0
    private let maxPackets = 5000
    /// Caches full process names resolved from a PID, since the per-packet PKTAP
    /// `comm` field is capped at 16 characters by the kernel. Keyed by PID but
    /// validated by process start time, so a reused PID never serves the previous
    /// process's name.
    private var processNameCache: [Int32: (start: UInt64, name: String)] = [:]

    /// Refreshes the helper registration state from the system.
    func refreshState() {
        switch daemon.status {
        case .enabled: helperState = .enabled
        case .requiresApproval: helperState = .requiresApproval
        default: helperState = .notRegistered
        }
    }

    /// Registers the helper (first run) and guides the user to approve it.
    func enableHelper() {
        do {
            try daemon.register()
        } catch {
            lastError = "Registration failed: \(error.localizedDescription)"
        }
        refreshState()
        if helperState != .enabled {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    /// Removes the helper.
    func disableHelper() {
        stopCapture()
        try? daemon.unregister()
        refreshState()
    }

    /// Unregisters then re-registers the helper. Needed after an app update: the
    /// previously-registered daemon keeps running the *old* helper binary until
    /// it is re-registered, so capture would silently use stale code.
    func reinstallHelper() {
        stopCapture()
        try? daemon.unregister()
        lastError = nil
        enableHelper()
    }

    func startCapture() {
        guard !isCapturing else { return }
        lastError = nil
        refreshState()
        guard helperState == .enabled else {
            enableHelper()
            return
        }
        let connection = NSXPCConnection(machServiceName: CaptureXPC.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: CaptureControl.self)
        connection.exportedInterface = NSXPCInterface(with: CaptureClient.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.isCapturing = false
                self?.endAttributionSession()
            }
        }
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor in
                self?.isCapturing = false
                self?.lastError = "Helper interrupted — press Start to reconnect."
                self?.endAttributionSession()
            }
        }
        connection.resume()
        self.connection = connection

        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            Task { @MainActor in
                self?.isCapturing = false
                self?.lastError = error.localizedDescription
            }
        } as? CaptureControl
        proxy?.startCapture(bpfFilter: nil) { [weak self] success, error in
            Task { @MainActor in
                self?.isCapturing = success
                if !success { self?.lastError = error ?? "Capture failed to start" }
            }
        }
    }

    func stopCapture() {
        (connection?.remoteObjectProxy as? CaptureControl)?.stopCapture()
        connection?.invalidate()
        connection = nil
        isCapturing = false
        endAttributionSession()
    }

    /// Tells the aggregator the packet-derived overlay is over, so the merged
    /// usage/traffic views fall back to the live NStat figures instead of
    /// freezing at the last captured totals (idempotent; also fired when the
    /// helper connection dies mid-capture).
    private func endAttributionSession() {
        guard let attribution else { return }
        Task { await attribution.endCaptureSession() }
    }

    func clear() {
        packets.removeAll()
    }

    // MARK: - CaptureClient (called by the helper, off the main actor)

    nonisolated func didCapture(_ batch: Data) {
        // Decode and dissect off the main actor; deliver finished rows to the UI
        // so high packet rates never stall rendering.
        Task.detached(priority: .utility) { [weak self] in
            let dissector = PacketDissector()
            let rows = WirePacketBatch.decode(batch).map { packet -> DissectedRow in
                let bytes = [UInt8](packet.data)
                // pktap reports each packet's inner link type: 1 = Ethernet
                // (en*), 0 = BSD loopback/NULL (lo0), everything else (e.g. 12 =
                // raw IP on utun*) is a bare IP packet.
                let linkType: LinkLayerType = switch packet.dlt {
                case 1: .ethernet
                case 0: .nullLoopback
                default: .rawIP
                }
                // Light dissection only: the per-field tree is the costly part to
                // build for every packet (string-heavy), and it is needed solely
                // when the user selects a packet to inspect — the detail view
                // rebuilds it on demand from `bytes`. The summary, protocol path,
                // five-tuple, hostnames, JA4 and TCP segment are all still produced.
                return DissectedRow(
                    packet: packet,
                    bytes: bytes,
                    linkType: linkType,
                    dissected: dissector.dissect(bytes, linkType: linkType, detailed: false)
                )
            }
            await self?.append(rows)
        }
    }

    /// A dissected packet awaiting a display id (assigned on the main actor).
    private struct DissectedRow {
        let packet: WirePacket
        let bytes: [UInt8]
        let linkType: LinkLayerType
        let dissected: DissectedPacket
    }

    private func append(_ rows: [DissectedRow]) {
        for row in rows {
            packets.append(PacketRow(
                id: nextID,
                timestamp: Date(timeIntervalSince1970: row.packet.timestamp),
                processName: fullProcessName(pid: row.packet.pid, fallback: row.packet.processName),
                pid: row.packet.pid,
                direction: direction(from: row.packet.direction),
                summary: row.dissected.summary,
                protocolPath: row.dissected.protocolPath,
                bytes: row.bytes,
                linkType: row.linkType
            ))
            nextID += 1
        }
        if packets.count > maxPackets {
            packets.removeFirst(packets.count - maxPackets)
        }
        attribute(rows)
    }

    /// Resolves a process's full name from its PID via `proc_pidpath` (cached),
    /// because PKTAP's per-packet `comm` field is truncated to 16 characters. Uses
    /// the same display-name derivation as connections for consistency; falls back
    /// to the truncated `comm` when the path can't be read (e.g. another user).
    private func fullProcessName(pid: Int32, fallback: String) -> String {
        guard pid > 0 else { return fallback }
        let start = Self.processStartTime(pid)
        if let cached = processNameCache[pid], cached.start == start { return cached.name }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0,
              let path = String(bytes: buffer.prefix(Int(length)), encoding: .utf8),
              !path.isEmpty else { return fallback }
        let name = AppIdentity(pid: pid, executablePath: path).displayName
        processNameCache[pid] = (start, name)
        return name
    }

    /// Process start time in seconds since the epoch via libproc, or 0 if it can't
    /// be read. Pairs with the PID in `processNameCache` so a reused PID misses.
    private static func processStartTime(_ pid: Int32) -> UInt64 {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size)
        }
        return read == size ? UInt64(info.pbi_start_tvsec) : 0
    }

    /// Forwards captured packets to the aggregator (off the main actor) so real
    /// per-connection/per-app byte totals accumulate while capturing, and records
    /// any SNI/DNS hostnames so connections show the host the app actually
    /// requested (preferred over reverse DNS).
    private func attribute(_ rows: [DissectedRow]) {
        guard let attribution else { return }
        let attributions = rows.compactMap { row -> ConnectionAggregator.PacketAttribution? in
            guard let tuple = row.dissected.fiveTuple else { return nil }
            return ConnectionAggregator.PacketAttribution(
                flowKey: tuple.flowKey,
                pid: row.packet.pid,
                inbound: row.packet.direction == 2,
                bytes: row.packet.originalLength
            )
        }
        let hostnames = rows.flatMap(\.dissected.hostnames).map {
            ConnectionAggregator.HostnameEntry(name: $0.name, ip: $0.ip)
        }
        let fingerprints = rows.compactMap { row -> ConnectionAggregator.FingerprintEntry? in
            guard let ja4 = row.dissected.tlsClientFingerprint, let tuple = row.dissected.fiveTuple else { return nil }
            return ConnectionAggregator.FingerprintEntry(ja4: ja4, flowKey: tuple.flowKey, pid: row.packet.pid)
        }
        let segments = rows.compactMap { row -> ConnectionAggregator.TCPSegmentEntry? in
            guard let tcp = row.dissected.tcpSegment, let tuple = row.dissected.fiveTuple else { return nil }
            return ConnectionAggregator.TCPSegmentEntry(
                segment: tcp,
                timestampMicros: UInt64((row.packet.timestamp * 1_000_000).rounded()),
                inbound: row.packet.direction == 2,
                flowKey: tuple.flowKey,
                pid: row.packet.pid
            )
        }
        guard !attributions.isEmpty || !hostnames.isEmpty || !fingerprints.isEmpty || !segments.isEmpty else { return }
        // Hand each kind over as one batch (one actor hop apiece) instead of one
        // `await` per item: a TCP-heavy batch previously cost ~one hop per segment
        // (each also re-entering the correlator), thrashing the shared aggregator.
        Task.detached {
            if !attributions.isEmpty { await attribution.attributePackets(attributions) }
            if !hostnames.isEmpty { await attribution.recordHostnames(hostnames) }
            if !fingerprints.isEmpty { await attribution.recordFingerprints(fingerprints) }
            if !segments.isEmpty { await attribution.recordTCPSegments(segments) }
        }
    }

    private func direction(from raw: UInt8) -> TrafficDirection {
        switch raw {
        case 1: .outbound
        case 2: .inbound
        default: .unknown
        }
    }
}
