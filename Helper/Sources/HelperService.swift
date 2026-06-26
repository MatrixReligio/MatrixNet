import Foundation
import MatrixNetXPC

/// XPC service vended by the privileged helper. Accepts a single connection from
/// a notarized, Developer ID-signed MatrixNet build by our team, then drives
/// PKTAP capture and streams `WirePacket` batches back to the app.
///
/// All mutable state (`engine`, `connection`) is confined to `stateQueue`, since
/// XPC delivers connection callbacks and per-connection messages on different
/// queues. The root daemon must never race on this state.
final class HelperService: NSObject, NSXPCListenerDelegate, CaptureControl, @unchecked Sendable {
    static let version = "0.1.0"

    /// Accept only a notarized Developer ID build of our app from our team:
    /// `1[…6.2.6]` = Developer ID CA, `leaf[…6.1.13]` = Developer ID Application,
    /// which (unlike a bare `anchor apple generic`) rejects development-signed builds.
    private static let clientRequirement = """
    anchor apple generic \
    and certificate 1[field.1.2.840.113635.100.6.2.6] \
    and certificate leaf[field.1.2.840.113635.100.6.1.13] \
    and certificate leaf[subject.OU] = "4DUQGD879H" \
    and identifier "com.matrixreligio.matrixnet"
    """

    private let stateQueue = DispatchQueue(label: "com.matrixreligio.matrixnet.helper.state")
    private var engine: PKTAPCaptureEngine?
    private var connection: NSXPCConnection?

    func listener(_: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // OS-enforced caller verification (macOS 13+).
        newConnection.setCodeSigningRequirement(Self.clientRequirement)

        return stateQueue.sync {
            // Single active connection: reject (don't hijack) a second caller.
            guard connection == nil else {
                newConnection.invalidate()
                return false
            }
            newConnection.exportedInterface = NSXPCInterface(with: CaptureControl.self)
            newConnection.exportedObject = self
            newConnection.remoteObjectInterface = NSXPCInterface(with: CaptureClient.self)
            newConnection.invalidationHandler = { [weak self] in self?.teardown() }
            newConnection.interruptionHandler = { [weak self] in self?.teardown() }
            connection = newConnection
            newConnection.resume()
            return true
        }
    }

    private func teardown() {
        stateQueue.sync {
            engine?.stop()
            engine = nil
            connection = nil
        }
    }

    // MARK: - CaptureControl

    func handshake(withReply reply: @escaping (String) -> Void) {
        reply("MatrixNetHelper \(Self.version)")
    }

    func startCapture(bpfFilter _: String?, withReply reply: @escaping (Bool, String?) -> Void) {
        // bpfFilter is reserved; with no filter installed BPF delivers all packets
        // (the analyzer filters client-side). Kernel BIOCSETF is a future addition.
        stateQueue.sync {
            engine?.stop()
            // Snapshot the connection now so delivery always targets this caller.
            let target = connection
            let engine = PKTAPCaptureEngine { packets in
                let client = target?.remoteObjectProxyWithErrorHandler { _ in } as? CaptureClient
                client?.didCapture(WirePacketBatch.encode(packets))
            }
            if let error = engine.start() {
                reply(false, error)
            } else {
                self.engine = engine
                reply(true, nil)
            }
        }
    }

    func stopCapture() {
        stateQueue.sync {
            engine?.stop()
            engine = nil
        }
    }
}
