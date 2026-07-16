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
    }

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        panel.reload()
    }
}
