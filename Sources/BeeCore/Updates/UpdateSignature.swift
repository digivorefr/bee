import CryptoKit
import Foundation

/// The signature that proves an update archive was published by the holder of the release key.
///
/// The archive is downloaded from GitHub, and what installs it bypasses Gatekeeper: without this check,
/// whoever could publish a release could run code on every Mac that updates. The private key never leaves
/// the publisher's Keychain; the application carries the public half.
public enum UpdateSignature {
    /// True when `signature` (Base64 of a 64-byte Ed25519 signature) was made over `data` with the private
    /// half of `publicKey` (Base64 of the 32-byte key). Whitespace around either is ignored.
    public static func isValid(signature: String, of data: Data, publicKey: String) -> Bool {
        guard let keyBytes = Data(base64Encoded: publicKey.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes),
              let signatureBytes = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)),
              signatureBytes.count == 64
        else { return false }
        return key.isValidSignature(signatureBytes, for: data)
    }
}
