import Foundation
import CryptoKit

/// Stable fingerprint of a pack's Telegram-side contents, computed over the
/// ordered remote unique IDs. Count comparison alone misses "one sticker
/// removed, one added"; the hash also catches reorders.
enum SourceFingerprint {

    static func hash(of remoteIDs: [String]) -> String {
        let digest = SHA256.hash(data: Data(remoteIDs.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.prefix(12).joined()
    }
}
