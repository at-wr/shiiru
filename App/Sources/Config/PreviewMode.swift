import Foundation
import TDLibKit

enum PreviewMode {
    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains("-ShiiruUIPreview")
    }

    static var isAuthPreview: Bool {
        ProcessInfo.processInfo.arguments.contains("-ShiiruAuthPreview")
    }

    static var authPreviewStep: String? {
        UserDefaults.standard.string(forKey: "ShiiruAuthPreview")
    }

    static var uiPreviewTab: String? {
        UserDefaults.standard.string(forKey: "ShiiruUIPreview")
    }

    static var sampleCodeInfo: AuthenticationCodeInfo {
        AuthenticationCodeInfo(
            nextType: nil,
            phoneNumber: "15551234567",
            timeout: 60,
            type: .authenticationCodeTypeSms(.init(length: 5))
        )
    }

    static var samplePasswordState: AuthorizationStateWaitPassword {
        AuthorizationStateWaitPassword(
            hasPassportData: false,
            hasRecoveryEmailAddress: true,
            passwordHint: "favorite duck",
            recoveryEmailAddressPattern: "a•••@e•••.com"
        )
    }

    static var sampleSets: [StickerSetInfo] {
        [
            makeSet(id: 9001, title: "Utya Duck", name: "utya", size: 120),
            makeSet(
                id: 9002,
                title: "An Extremely Long Sticker Pack Title That Must Truncate Nicely",
                name: "longtitle",
                size: 48
            ),
            makeSet(id: 9003, title: "Resistance Dog", name: "resistancedog", size: 24),
            makeSet(id: 9004, title: "Kotatsu Neko", name: "kotatsuneko", size: 30),
        ]
    }

    static func preparePreferences() {
        guard !Preferences.hasSeenPackList else { return }
        Preferences.hasSeenPackList = true
        Preferences.knownPackIDs = Set(sampleSets.dropFirst().map { String($0.id.rawValue) })
    }

    private static func makeSet(id: Int64, title: String, name: String, size: Int) -> StickerSetInfo {
        StickerSetInfo(
            covers: [],
            id: TdInt64(id),
            isAllowedAsChatEmojiStatus: false,
            isArchived: false,
            isInstalled: true,
            isOfficial: false,
            isOwned: false,
            isViewed: true,
            name: name,
            needsRepainting: false,
            size: size,
            stickerType: .stickerTypeRegular,
            thumbnail: nil,
            thumbnailOutline: nil,
            title: title
        )
    }
}
