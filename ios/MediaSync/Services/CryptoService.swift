import CryptoKit
import Foundation

/// Client-side encryption: media is sealed with AES-256-GCM before it leaves the device, so the
/// backend / object store only ever sees ciphertext. The key lives in the Keychain and is marked
/// synchronizable so iCloud Keychain can share it across the user's devices.
enum CryptoService {
    private static let account = "media-encryption-key"

    static var key: SymmetricKey {
        if let data = KeychainStore.load(account: account, synchronizable: true) {
            return SymmetricKey(data: data)
        }
        let new = SymmetricKey(size: .bits256)
        KeychainStore.save(new.withUnsafeBytes { Data($0) }, account: account, synchronizable: true)
        return new
    }

    /// Returns nonce || ciphertext || tag.
    static func encrypt(_ plaintext: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(plaintext, using: key).combined else {
            throw CocoaError(.coderInvalidValue)
        }
        return combined
    }

    static func decrypt(_ combined: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key)
    }

    static func sha256Hex(of file: URL) throws -> String {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
