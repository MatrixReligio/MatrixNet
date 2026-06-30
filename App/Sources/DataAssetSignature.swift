import Foundation
import MatrixNetModel
import os

/// Verifies a downloaded data asset (GeoIP / threat list) against an Ed25519
/// signature published next to it as `<asset>.edsig` (base64), using the app's
/// Sparkle public key (`SUPublicEDKey`). The bundled copy inside the notarized
/// app is already integrity-protected by the code signature, so only the
/// out-of-band rolling download needs this check.
///
/// Fail-closed: a missing key, a missing/unreachable signature, or any mismatch
/// returns `false`, so the caller keeps the trusted bundled/previous asset rather
/// than installing unverified data.
enum DataAssetSignature {
    private static let log = Logger(subsystem: "com.matrixreligio.matrixnet", category: "asset-signature")

    static func isValid(data: Data, signatureURL: URL) async -> Bool {
        guard let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !publicKey.isEmpty
        else {
            log.warning("No SUPublicEDKey available; cannot verify data-asset signature.")
            return false
        }
        var request = URLRequest(url: signatureURL)
        request.timeoutInterval = 15
        guard let (signatureData, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let signatureBase64 = String(data: signatureData, encoding: .utf8)
        else {
            return false
        }
        return EdSignatureVerifier.isValid(
            data: data,
            signatureBase64: signatureBase64,
            publicKeyBase64: publicKey
        )
    }
}
