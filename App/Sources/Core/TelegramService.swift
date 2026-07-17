import Foundation
import Combine
import UIKit
import TDLibKit

@MainActor
final class TelegramService: ObservableObject {

    enum AuthState: Equatable {
        case starting
        case waitPhoneNumber
        case waitCode(AuthenticationCodeInfo)
        case waitRegistration
        case waitPassword(AuthorizationStateWaitPassword)
        case ready
        case loggingOut

        var isAuthorized: Bool { self == .ready }
    }

    static let shared = TelegramService()

    @Published private(set) var authState: AuthState = .starting
    @Published private(set) var user: User?
    /// True while TDLib's network connection is fully established.
    @Published private(set) var isConnected = false

    private let manager = TDLibClientManager()
    private var client: TDLibClient!

    private init() {
        createClient()
    }

    private func createClient() {
        client = manager.createClient { [weak self] data, client in
            guard let update = try? client.decoder.decode(Update.self, from: data) else { return }
            Task { @MainActor [weak self] in
                self?.handle(update: update)
            }
        }

        _ = try? client.execute(query: DTO(SetLogVerbosityLevel(newVerbosityLevel: 1)))
    }

    private func handle(update: Update) {
        switch update {
        case .updateAuthorizationState(let state):
            handle(authorizationState: state.authorizationState)
        case .updateConnectionState(let update):
            isConnected = update.state == .connectionStateReady
            // A getMe that raced the connection coming up leaves the
            // Settings profile header on its "?" placeholder for the whole
            // session (seen in field logs); retry once online.
            if isConnected, authState == .ready, user == nil {
                Task { await self.refreshUser() }
            }
        case .updateUser(let update) where update.user.id == user?.id:
            // Name/avatar edits made in Telegram propagate live.
            user = update.user
        default:
            break
        }
    }

    private func handle(authorizationState state: AuthorizationState) {
        switch state {
        case .authorizationStateWaitTdlibParameters:
            sendTdlibParameters()
        case .authorizationStateWaitPhoneNumber:
            authState = .waitPhoneNumber
        case .authorizationStateWaitCode(let wait):
            authState = .waitCode(wait.codeInfo)
        case .authorizationStateWaitRegistration:
            authState = .waitRegistration
        case .authorizationStateWaitPassword(let wait):
            authState = .waitPassword(wait)
        case .authorizationStateReady:
            authState = .ready
            Task { await self.refreshUser() }
        case .authorizationStateLoggingOut, .authorizationStateClosing:
            authState = .loggingOut
        case .authorizationStateClosed:

            user = nil
            avatarCache = nil
            authState = .starting
            createClient()
        default:

            break
        }
    }

    private func sendTdlibParameters() {
        let library = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let device = UIDevice.current
        Task {
            _ = try? await client.setTdlibParameters(
                apiHash: TelegramConfig.apiHash,
                apiId: TelegramConfig.apiID,
                applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
                databaseDirectory: library.appendingPathComponent("tdlib").path,
                databaseEncryptionKey: nil,
                deviceModel: device.model,
                filesDirectory: caches.appendingPathComponent("tdlib-files").path,
                systemLanguageCode: Locale.current.language.languageCode?.identifier ?? "en",
                systemVersion: device.systemVersion,
                useChatInfoDatabase: false,
                useFileDatabase: true,
                useMessageDatabase: false,
                useSecretChats: false,
                useTestDc: TelegramConfig.useTestDC
            )
        }
    }

    private var refreshingUser = false

    private func refreshUser() async {
        guard !refreshingUser else { return }
        refreshingUser = true
        defer { refreshingUser = false }
        // getMe normally answers from TDLib's local database, but a
        // cold-start race can fail the first attempt — and a single
        // swallowed failure used to leave `user` nil until relaunch.
        for attempt in 0..<3 {
            if let me = try? await client.getMe() {
                user = me
                break
            }
            try? await Task.sleep(nanoseconds: UInt64(1 << attempt) * 1_000_000_000)
        }
        _ = await avatarImage()
    }

    private var avatarCache: (fileID: Int, image: UIImage)?

    var cachedAvatarImage: UIImage? {
        guard let file = user?.profilePhoto?.small,
              let cached = avatarCache, cached.fileID == file.id
        else { return nil }
        return cached.image
    }

    func avatarImage() async -> UIImage? {
        guard let file = user?.profilePhoto?.small else { return nil }
        if let cached = avatarCache, cached.fileID == file.id { return cached.image }
        guard let path = try? await download(file: file),
              let image = UIImage(contentsOfFile: path)
        else { return nil }
        avatarCache = (file.id, image)
        return image
    }

    func submitPhoneNumber(_ phoneNumber: String) async throws {
        _ = try await client.setAuthenticationPhoneNumber(phoneNumber: phoneNumber, settings: nil)
    }

    func submitCode(_ code: String) async throws {
        _ = try await client.checkAuthenticationCode(code: code)
    }

    func submitRegistration(firstName: String, lastName: String) async throws {
        _ = try await client.registerUser(disableNotification: false, firstName: firstName, lastName: lastName)
    }

    func submitPassword(_ password: String) async throws {
        _ = try await client.checkAuthenticationPassword(password: password)
    }

    func resendCode() async throws {
        _ = try await client.resendAuthenticationCode(reason: nil)
    }

    func requestPasswordRecovery() async throws {
        _ = try await client.requestAuthenticationPasswordRecovery()
    }

    func recoverPassword(code: String) async throws {
        _ = try await client.recoverAuthenticationPassword(
            newHint: nil,
            newPassword: nil,
            recoveryCode: code
        )
    }

    func logOut() async {
        _ = try? await client.logOut()
    }

    /// Waits for the stored session to authorize and the connection to come
    /// up — used by background maintenance, where the app launches headless.
    func waitUntilReady(timeout: TimeInterval) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline, !Task.isCancelled {
            if authState == .ready, isConnected { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return authState == .ready && isConnected
    }

    func installedStickerSets() async throws -> [StickerSetInfo] {
        try await client.getInstalledStickerSets(stickerType: .stickerTypeRegular).sets
    }

    func customEmojiSets() async throws -> [StickerSetInfo] {
        try await client.getInstalledStickerSets(stickerType: .stickerTypeCustomEmoji).sets
    }

    func savedAnimations() async throws -> [Animation] {
        try await client.getSavedAnimations().animations
    }

    func stickerSet(id: TdInt64) async throws -> StickerSet {
        try await client.getStickerSet(setId: id)
    }

    @discardableResult
    func downloadStarting(file: File) async throws -> File {
        try await client.downloadFile(
            fileId: file.id,
            limit: 0,
            offset: 0,
            priority: 24,
            synchronous: false
        )
    }

    func download(file: File) async throws -> String {
        if file.local.isDownloadingCompleted, !file.local.path.isEmpty {
            return file.local.path
        }
        let downloaded = try await client.downloadFile(
            fileId: file.id,
            limit: 0,
            offset: 0,
            priority: 32,
            synchronous: true
        )
        guard downloaded.local.isDownloadingCompleted, !downloaded.local.path.isEmpty else {
            NSLog("[Shiiru] download incomplete for file %d", file.id)
            throw ShiiruError.downloadFailed
        }
        return downloaded.local.path
    }
}

enum ShiiruError: LocalizedError {
    case downloadFailed
    case unsupportedSticker
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .downloadFailed: return "The sticker could not be downloaded from Telegram."
        case .unsupportedSticker: return "This sticker format is not supported."
        case .conversionFailed: return "The sticker could not be converted for iMessage."
        }
    }
}

extension TDLibKit.Error {

    var friendlyMessage: String {
        switch message {
        case "PHONE_NUMBER_INVALID": return "That phone number doesn't look right. Use the international format, e.g. +1 555 123 4567."
        case "PHONE_CODE_INVALID": return "Wrong code. Double-check the code Telegram sent you."
        case "PHONE_CODE_EXPIRED": return "That code expired. Request a new one."
        case "PASSWORD_HASH_INVALID": return "Incorrect password. Try again."
        case "Too Many Requests: retry after X", _ where message.hasPrefix("Too Many Requests"):
            return "Too many attempts. Please wait a moment and try again."
        default: return message
        }
    }
}
