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
    private var controlSocket: Int32 = -1
    private var pktapInterface: String?
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.matrixreligio.matrixnet.helper.capture")
    private var bufferLength = 0
    private let onBatch: ([WirePacket]) -> Void

    /// Link types that indicate pktap framing is active. The macOS *kernel* BPF
    /// reports pktap as DLT 149 (verified on macOS 26); libpcap remaps it to the
    /// registered DLT_PKTAP value 258 in userspace. Accept either. DLT_RAW (12)
    /// here means pktap headers were not enabled.
    private static let pktapLinkTypes: Set<UInt32> = [149, 258]

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
        // `pktap` is a *cloning* pseudo-interface: it must be created with
        // SIOCIFCREATE before a BPF descriptor can bind to it. Binding to the
        // bare name "pktap" fails with ENXIO. A freshly created, unfiltered
        // pktap taps every interface (en0, utun*, lo0, …) with per-packet
        // process attribution — exactly what we want. This mirrors how Apple's
        // own libpcap implements `pcap_open_live("pktap", …)` (pcap-darwin.c).
        let interfaceName = try createPKTAPInterface()
        pktapInterface = interfaceName

        let descriptor = try openFreeBPF()
        fileDescriptor = descriptor

        // Request a larger kernel buffer before binding (the default is tiny —
        // ~4 KB — which causes frequent wakeups and drops under load). The kernel
        // clamps to its maximum if this is too large.
        var requestedBuffer: UInt32 = 512 * 1024
        _ = ioctl(descriptor, IOCTL.bIOCSBLEN, &requestedBuffer)

        // Request pktap headers BEFORE binding. Without this the kernel delivers
        // plain DLT_RAW (no process attribution); with it, each packet is framed
        // with a pktap_header (pid + process name) and the link type becomes
        // DLT_PKTAP. Verified on macOS 26; see docs/superpowers/notes.
        var want: UInt32 = 1
        guard ioctl(descriptor, IOCTL.bIOCSWantPKTAP, &want) >= 0 else {
            throw CaptureError.wantPKTAP(errno)
        }

        // Bind the BPF device to the created pktap interface.
        var request = ifreq(name: interfaceName)
        guard ioctl(descriptor, IOCTL.bIOCSETIF, &request) >= 0 else {
            throw CaptureError.setInterface(errno)
        }

        // With BIOCSWANTPKTAP set, the kernel frames each packet with a
        // pktap_header and reports DLT 149. (Setting BIOCSDLT to libpcap's 258 is
        // rejected with EINVAL by the kernel, so we don't attempt it.) Confirm
        // pktap mode is actually active — DLT_RAW (12) would mean no process
        // attribution, which defeats the purpose.
        var actualDLT: UInt32 = 0
        guard ioctl(descriptor, IOCTL.bIOCGDLT, &actualDLT) >= 0,
              Self.pktapLinkTypes.contains(actualDLT)
        else {
            throw CaptureError.unexpectedDLT(actualDLT)
        }

        // Immediate mode: deliver packets as they arrive (set after SETIF/SDLT,
        // matching libpcap's ordering).
        var enable: UInt32 = 1
        _ = ioctl(descriptor, IOCTL.bIOCIMMEDIATE, &enable)

        // Read the negotiated kernel buffer length.
        var length: UInt32 = 0
        _ = ioctl(descriptor, IOCTL.bIOCGBLEN, &length)
        bufferLength = Int(length) > 0 ? Int(length) : 32768
    }

    /// Creates a `pktap` clone interface and returns the kernel-assigned name
    /// (e.g. `pktap0`). The control socket is kept open so the interface can be
    /// destroyed in `cleanup()`.
    private func createPKTAPInterface() throws -> String {
        let socketFD = socket(AF_INET, SOCK_DGRAM, 0)
        guard socketFD >= 0 else { throw CaptureError.createInterface(errno) }
        controlSocket = socketFD

        var request = ifreq(name: "pktap")
        guard ioctl(socketFD, IOCTL.siocIFCreate, &request) >= 0 else {
            throw CaptureError.createInterface(errno)
        }
        return request.interfaceName
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
        // Destroy the cloned pktap interface so it doesn't leak across sessions.
        if controlSocket >= 0 {
            if let name = pktapInterface {
                var request = ifreq(name: name)
                _ = ioctl(controlSocket, IOCTL.siocIFDestroy, &request)
            }
            close(controlSocket)
            controlSocket = -1
        }
        pktapInterface = nil
    }

    enum CaptureError: Error {
        case openDevice(Int32)
        case createInterface(Int32)
        case wantPKTAP(Int32)
        case setInterface(Int32)
        case unexpectedDLT(UInt32)
    }
}

private extension ifreq {
    /// Builds an `ifreq` with `ifr_name` set from a Swift string (truncated to
    /// the 16-byte `IFNAMSIZ` field, NUL-padded).
    init(name: String) {
        self.init()
        withUnsafeMutableBytes(of: &ifr_name) { raw in
            for (index, byte) in name.utf8.enumerated() where index < raw.count - 1 {
                raw[index] = byte
            }
        }
    }

    /// Reads `ifr_name` back as a Swift string (e.g. the kernel-assigned clone
    /// name after `SIOCIFCREATE`).
    var interfaceName: String {
        var copy = self
        return withUnsafeBytes(of: &copy.ifr_name) { raw in
            String(bytes: raw.prefix { $0 != 0 }, encoding: .utf8) ?? ""
        }
    }
}
