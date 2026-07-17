import UIKit
import Messages

final class MessagesViewController: MSMessagesAppViewController {

    private let panel = StickerPanelViewController()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        addChild(panel)
        panel.view.frame = view.bounds
        panel.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(panel.view)
        panel.didMove(toParent: self)

        panel.onOpenApp = { [weak self] in
            guard let url = URL(string: "shiiru://") else { return }
            self?.extensionContext?.open(url)
        }

        // Tapping a sticker stages it in the Messages input field — same
        // behavior MSStickerView's tap gesture provided.
        panel.onSelectSticker = { [weak self] sticker in
            self?.activeConversation?.insert(sticker) { error in
                if let error {
                    NSLog("[Shiiru] Failed to insert sticker: \(error)")
                }
            }
        }
    }

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        panel.reload()
        panel.startWatchingManifest()
    }

    override func didBecomeActive(with conversation: MSConversation) {
        super.didBecomeActive(with: conversation)
        panel.reloadIfManifestChanged()
    }
}
