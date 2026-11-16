import Foundation
import Network
import Security

/// A throwaway self-signed identity for 127.0.0.1 (valid for a century, PKCS#12 password "beetest"), generated only
/// for the TLS tests of the transport. It protects nothing and is trusted by nobody.
enum LoopbackIdentity {
    enum Failure: Error { case importFailed(OSStatus), noIdentity }

    static func make() throws -> sec_identity_t {
        let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) ?? Data()
        let options: [String: Any] = [kSecImportExportPassphrase as String: "beetest", kSecImportToMemoryOnly as String: true]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess else { throw Failure.importFailed(status) }
        guard let entry = (items as? [[String: Any]])?.first,
              let value = entry[kSecImportItemIdentity as String],
              CFGetTypeID(value as CFTypeRef) == SecIdentityGetTypeID(),
              let identity = sec_identity_create(value as! SecIdentity)
        else { throw Failure.noIdentity }
        return identity
    }

    private static let base64 = """
        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
        """
}
