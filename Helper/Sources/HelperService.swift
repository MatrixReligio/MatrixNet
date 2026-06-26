import Foundation
import MatrixNetXPC

/// XPC service vended by the privileged helper. Accepts connections only from a
/// MatrixNet build signed by our team, then drives PKTAP capture and streams
/// `WirePacket` batches back to the app.
final class HelperService: NSObject, NSXPCListenerDelegate, CaptureControl, @unchecked Sendable {
    static let version = "0.1.0"

    /// Only a binary signed by our Team ID with our bundle id may connect.
    private static let clientRequirement = """
    anchor apple generic \
    and certificate leaf[subject.OU] = "4DUQGD879H" \
    and identifier "com.matrixreligio.matrixnet"
    """

    private var engine: PKTAPCaptureEngine?
    private weak var connection: NSXPCConnection?

    func listener(_: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // OS-enforced caller verification (macOS 13+): rejects unsigned/foreign callers.
        newConnection.setCodeSigningRequirement(Self.clientRequirement)
        newConnection.exportedInterface = NSXPCInterface(with: CaptureControl.self)
        newConnection.exportedObject = self
        newConnection.remoteObjectInterface = NSXPCInterface(with: CaptureClient.self)
        newConnection.invalidationHandler = { [weak self] in
            self?.engine?.stop()
            self?.engine = nil
        }
        connection = newConnection
        newConnection.resume()
        return true
    }

    // MARK: - CaptureControl

    func handshake(withReply reply: @escaping (String) -> Void) {
        reply("MatrixNetHelper \(Self.version)")
    }

    func startCapture(bpfFilter _: String?, withReply reply: @escaping (Bool, String?) -> Void) {
        engine?.stop()
        let engine = PKTAPCaptureEngine { [weak self] packets in
            guard let client = self?.connection?.remoteObjectProxy as? CaptureClient else { return }
            client.didCapture(WirePacketBatch.encode(packets))
        }
        if let error = engine.start() {
            reply(false, error)
        } else {
            self.engine = engine
            reply(true, nil)
        }
    }

    func stopCapture() {
        engine?.stop()
        engine = nil
    }
}
