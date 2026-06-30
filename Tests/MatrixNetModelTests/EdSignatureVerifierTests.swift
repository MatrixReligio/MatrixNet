import CryptoKit
import Foundation
import Testing
@testable import MatrixNetModel

@Suite("EdSignatureVerifier")
struct EdSignatureVerifierTests {
    private func keypair() -> (privateKey: Curve25519.Signing.PrivateKey, publicKeyBase64: String) {
        let priv = Curve25519.Signing.PrivateKey()
        return (priv, priv.publicKey.rawRepresentation.base64EncodedString())
    }

    @Test("accepts a genuine signature over the data")
    func acceptsGenuine() throws {
        let (priv, pubB64) = keypair()
        let data = Data("geoip-database-bytes".utf8)
        let sigB64 = try priv.signature(for: data).base64EncodedString()
        #expect(EdSignatureVerifier.isValid(data: data, signatureBase64: sigB64, publicKeyBase64: pubB64))
    }

    @Test("rejects a signature over different data (tampering)")
    func rejectsTampered() throws {
        let (priv, pubB64) = keypair()
        let sigB64 = try priv.signature(for: Data("original".utf8)).base64EncodedString()
        #expect(!EdSignatureVerifier.isValid(
            data: Data("tampered".utf8),
            signatureBase64: sigB64,
            publicKeyBase64: pubB64
        ))
    }

    @Test("rejects a signature made with a different key")
    func rejectsWrongKey() throws {
        let (priv, _) = keypair()
        let (_, otherPubB64) = keypair()
        let data = Data("payload".utf8)
        let sigB64 = try priv.signature(for: data).base64EncodedString()
        #expect(!EdSignatureVerifier.isValid(data: data, signatureBase64: sigB64, publicKeyBase64: otherPubB64))
    }

    @Test("rejects malformed base64 inputs")
    func rejectsMalformed() {
        let data = Data("payload".utf8)
        #expect(!EdSignatureVerifier.isValid(data: data, signatureBase64: "not base64!!", publicKeyBase64: "also bad"))
        #expect(!EdSignatureVerifier.isValid(data: data, signatureBase64: "", publicKeyBase64: ""))
    }
}
