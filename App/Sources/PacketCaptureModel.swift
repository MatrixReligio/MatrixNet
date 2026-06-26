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
    private let dissector = PacketDissector()
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
        connection.resume()
        self.connection = connection

        let proxy = connection.remoteObjectProxy as? CaptureControl
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
        let wire = WirePacketBatch.decode(batch)
        Task { @MainActor in self.ingest(wire) }
    }

    private func ingest(_ wire: [WirePacket]) {
        for packet in wire {
            let linkType: LinkLayerType = packet.dlt == 1 ? .ethernet : .rawIP
            let bytes = [UInt8](packet.data)
            let dissected = dissector.dissect(bytes, linkType: linkType)
            packets.append(PacketRow(
                id: nextID,
                timestamp: Date(timeIntervalSince1970: packet.timestamp),
                processName: packet.processName,
                pid: packet.pid,
                direction: direction(from: packet.direction),
                summary: dissected.summary,
                protocolPath: dissected.protocolPath,
                layers: dissected.layers,
                bytes: bytes
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
