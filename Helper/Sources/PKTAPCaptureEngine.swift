import Darwin
import Foundation
import MatrixNetCapture
import MatrixNetModel
import MatrixNetXPC

/// Opens a BPF device bound to the kernel `pktap` pseudo-interface (DLT_PKTAP)
/// and streams captured packets — each carrying per-packet process attribution —
/// as `WirePacket` batches. Runs in the privileged helper (BPF requires root).
final class PKTAPCaptureEngine: @unchecked Sendable {
    private var fileDescriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.matrixreligio.matrixnet.helper.capture")
    private var bufferLength = 0
    private let onBatch: ([WirePacket]) -> Void

    /// DLT for the kernel packet-tap pseudo-device.
    private static let dltPKTAP: UInt32 = 258

    init(onBatch: @escaping ([WirePacket]) -> Void) {
        self.onBatch = onBatch
    }

    /// Starts capture. Returns an error message on failure, or `nil` on success.
    func start() -> String? {
        queue.sync {
            guard fileDescriptor < 0 else { return nil }
            do {
                try openDevice()
                startReading()
                return nil
            } catch {
                cleanup()
                return "\(error)"
            }
        }
    }

    func stop() {
        queue.sync { cleanup() }
    }

    // MARK: - BPF setup

    private func openDevice() throws {
        let descriptor = try openFreeBPF()
        fileDescriptor = descriptor

        var enable: UInt32 = 1
        // Immediate mode: deliver packets as they arrive.
        _ = ioctl(descriptor, IOCTL.bIOCIMMEDIATE, &enable)

        // Bind to the pktap pseudo-interface.
        var request = ifreq()
        withUnsafeMutableBytes(of: &request.ifr_name) { raw in
            for (index, byte) in "pktap".utf8.enumerated() where index < raw.count - 1 {
                raw[index] = byte
            }
        }
        guard ioctl(descriptor, IOCTL.bIOCSETIF, &request) >= 0 else {
            throw CaptureError.setInterface(errno)
        }

        // Select the PKTAP data link type.
        var dlt = Self.dltPKTAP
        guard ioctl(descriptor, IOCTL.bIOCSDLT, &dlt) >= 0 else {
            throw CaptureError.setDLT(errno)
        }

        // Read the negotiated kernel buffer length.
        var length: UInt32 = 0
        _ = ioctl(descriptor, IOCTL.bIOCGBLEN, &length)
        bufferLength = Int(length) > 0 ? Int(length) : 32768
    }

    private func openFreeBPF() throws -> Int32 {
        for index in 0 ..< 256 {
            let descriptor = open("/dev/bpf\(index)", O_RDONLY)
            if descriptor >= 0 { return descriptor }
            // EBUSY: device in use, try the next. Any other error (EPERM when not
            // root, etc.) is terminal — stop and report it accurately.
            if errno != EBUSY { throw CaptureError.openDevice(errno) }
        }
        throw CaptureError.openDevice(ENODEV)
    }

    private func startReading() {
        let descriptor = fileDescriptor
        let capacity = bufferLength
        let readSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        readSource.setEventHandler { [weak self] in
            self?.drain(descriptor: descriptor, capacity: capacity)
        }
        readSource.resume()
        source = readSource
    }

    private func drain(descriptor: Int32, capacity: Int) {
        var buffer = [UInt8](repeating: 0, count: capacity)
        let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, capacity) }
        guard count > 0 else { return }

        let rawPackets = BPFRecordParser.packets(in: buffer, count: count)
        let now = Date().timeIntervalSince1970
        let packets = rawPackets.compactMap { raw -> WirePacket? in
            guard let pktap = PKTAPParser.parse(raw) else { return nil }
            return WirePacket(
                timestamp: now,
                pid: pktap.pid,
                processName: pktap.processName,
                direction: directionByte(pktap.direction),
                dlt: pktap.dlt,
                originalLength: pktap.payload.count,
                data: Data(pktap.payload)
            )
        }
        if !packets.isEmpty { onBatch(packets) }
    }

    private func directionByte(_ direction: TrafficDirection) -> UInt8 {
        switch direction {
        case .outbound: 1
        case .inbound: 2
        case .unknown: 0
        }
    }

    private func cleanup() {
        source?.cancel()
        source = nil
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    enum CaptureError: Error {
        case openDevice(Int32)
        case setInterface(Int32)
        case setDLT(Int32)
    }
}
