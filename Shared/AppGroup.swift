import Foundation

enum AppGroup {
    static let identifier = "group.dev.alany.shiiru"

    static var containerURL: URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {

            fatalError("App Group container unavailable — check the \(identifier) entitlement")
        }
        return url
    }

    static var stickersDirectory: URL {
        containerURL.appendingPathComponent("Stickers", isDirectory: true)
    }

    static var manifestURL: URL {
        containerURL.appendingPathComponent("manifest.json")
    }
}
