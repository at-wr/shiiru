import Foundation

enum Preferences {
    private static let defaults = UserDefaults.standard

    private static let sharedDefaults = UserDefaults(suiteName: AppGroup.identifier) ?? .standard

    static var packOrder: [String] {
        get { sharedDefaults.stringArray(forKey: "packOrder") ?? [] }
        set { sharedDefaults.set(newValue, forKey: "packOrder") }
    }

    static var knownPackIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: "knownPackIDs") ?? []) }
        set { defaults.set(Array(newValue), forKey: "knownPackIDs") }
    }

    static var hasSeenPackList: Bool {
        get { defaults.bool(forKey: "hasSeenPackList") }
        set { defaults.set(newValue, forKey: "hasSeenPackList") }
    }

    static var autoAddNewPacks: Bool {
        get { defaults.bool(forKey: "autoAddNewPacks") }
        set { defaults.set(newValue, forKey: "autoAddNewPacks") }
    }
}
