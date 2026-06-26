import Foundation
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
    let layers: [DissectionNode]
    let bytes: [UInt8]

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

    private let daemon = SMAppService.daemon(plistName: CaptureXPC.helperPlistName)
    private var connection: NSXPCConnection?
    private var nextID: UInt64 = 0
    private let maxPackets = 5000

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

    func startCapture() {
        guard !isCapturing else { return }
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
            Task { @MainActor in self?.isCapturing = false }
        }
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor in
                self?.isCapturing = false
                self?.lastError = "Helper interrupted — press Start to reconnect."
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
                return DissectedRow(
                    packet: packet,
                    bytes: bytes,
                    dissected: dissector.dissect(bytes, linkType: linkType)
                )
            }
            await self?.append(rows)
        }
    }

    /// A dissected packet awaiting a display id (assigned on the main actor).
    private struct DissectedRow {
        let packet: WirePacket
        let bytes: [UInt8]
        let dissected: DissectedPacket
    }

    private func append(_ rows: [DissectedRow]) {
        for row in rows {
            packets.append(PacketRow(
                id: nextID,
                timestamp: Date(timeIntervalSince1970: row.packet.timestamp),
                processName: row.packet.processName,
                pid: row.packet.pid,
                direction: direction(from: row.packet.direction),
                summary: row.dissected.summary,
                protocolPath: row.dissected.protocolPath,
                layers: row.dissected.layers,
                bytes: row.bytes
            ))
            nextID += 1
        }
        if packets.count > maxPackets {
            packets.removeFirst(packets.count - maxPackets)
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
