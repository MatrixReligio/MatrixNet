import CryptoKit
import Foundation

/// Verifies Ed25519 (EdDSA) detached signatures — the same scheme Sparkle uses
/// for appcasts (`sign_update`). It lets the app check a downloaded data asset
/// (GeoIP / threat list) against its embedded public key before installing, so a
/// tampered-but-structurally-valid asset on the release host is rejected.
///
/// Both the signature and public key are base64, exactly as Sparkle emits the
/// signature (`sparkle:edSignature`) and stores the key (`SUPublicEDKey`).
public enum EdSignatureVerifier {
    public static func isValid(data: Data, signatureBase64: String, publicKeyBase64: String) -> Bool {
        guard let signature = decodeBase64(signatureBase64),
              let keyBytes = decodeBase64(publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)
        else {
            return false
        }
        return key.isValidSignature(signature, for: data)
    }

    private static func decodeBase64(_ string: String) -> Data? {
        Data(base64Encoded: string.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
