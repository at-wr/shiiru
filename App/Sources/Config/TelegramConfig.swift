import Foundation

enum TelegramConfig {
    static let apiID: Int = 0
    static let apiHash: String = ""

    static let useTestDC = false

    static var isConfigured: Bool {
        apiID != 0 && !apiHash.isEmpty
    }
}
