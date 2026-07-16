import UIKit

final class PrivacyPolicyViewController: UIViewController {

    static let policyText = """
    Shiiru Privacy Policy

    Last updated: July 15, 2026

    TL;DR: Shiiru collects nothing, tracks nothing, and has no \
    servers. Everything happens on your device.

    1. Your Telegram account
    Shiiru connects to Telegram using TDLib, Telegram's official client \
    library, directly from your device. Your phone number, verification \
    codes, and passwords are sent only to Telegram — never to us or anyone \
    else. Your Telegram session is stored in an encrypted TDLib database on \
    your device and can be ended at any time with Log Out (which also \
    invalidates the session on Telegram's side) or from another Telegram \
    client via Settings → Devices.

    2. Your stickers
    Sticker packs you choose to sync are downloaded from Telegram, converted \
    on-device, and stored in a private container shared only between the \
    Shiiru app and its iMessage extension. They never leave your device \
    except when you send one in a conversation.

    3. Analytics and tracking
    There are none. Shiiru contains no analytics, no advertising SDKs, no \
    crash reporters, and makes no network connections other than TDLib's \
    connection to Telegram.

    4. Data deletion
    "Remove All Synced Stickers" deletes all converted stickers. Logging out \
    additionally deletes the local Telegram session. Deleting the app removes \
    everything.

    5. Telegram
    Your use of Telegram through Shiiru remains subject to Telegram's own \
    Terms of Service and Privacy Policy (telegram.org/privacy).

    6. Changes
    If this policy ever changes, the updated text ships inside the app — the \
    same place you're reading now.
    """

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Privacy Policy"
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never

        let textView = UITextView()
        textView.text = Self.policyText
        textView.font = Theme.bodyFont()
        textView.textColor = .label
        textView.isEditable = false
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 20, left: 16, bottom: 32, right: 16)
        textView.frame = view.bounds
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textView.preferSoftTopEdge()
        view.addSubview(textView)
    }
}
