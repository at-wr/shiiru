import UIKit
import Combine
import TDLibKit

class OnboardingStepViewController: UIViewController {

    let heroContainer = UIStackView()
    let titleLabel = UILabel()
    let subtitleLabel = UILabel()
    let contentStack = UIStackView()
    let errorLabel = UILabel()
    let actionButton = FilledButton()

    private let scrollView = UIScrollView()
    private var cancellables = Set<AnyCancellable>()
    private var hasAnimatedEntrance = false
    private var lastKeyboardTop: CGFloat?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.backButtonDisplayMode = .minimal

        titleLabel.font = Theme.largeTitleFont()
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        subtitleLabel.font = Theme.bodyFont()
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0

        errorLabel.font = Theme.footnoteFont()
        errorLabel.textColor = .systemRed
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 0
        errorLabel.alpha = 0

        contentStack.axis = .vertical
        contentStack.spacing = 16

        heroContainer.axis = .vertical
        heroContainer.alignment = .center

        let headerStack = UIStackView(arrangedSubviews: [heroContainer, titleLabel, subtitleLabel])
        headerStack.axis = .vertical
        headerStack.spacing = 10
        headerStack.setCustomSpacing(18, after: heroContainer)

        let mainStack = UIStackView(arrangedSubviews: [headerStack, contentStack, errorLabel])
        mainStack.axis = .vertical
        mainStack.spacing = 28
        mainStack.setCustomSpacing(14, after: contentStack)
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.alwaysBounceVertical = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.preferSoftTopEdge()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(mainStack)
        view.addSubview(scrollView)

        actionButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(actionButton)

        let fitsVisibleArea = mainStack.heightAnchor.constraint(
            lessThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor, constant: -24
        )
        fitsVisibleArea.priority = UILayoutPriority(749)

        NSLayoutConstraint.activate([
            fitsVisibleArea,
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: actionButton.topAnchor, constant: -12),

            mainStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            mainStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -8),
            mainStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 24),
            mainStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -24),

            actionButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            actionButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            actionButton.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -16),
        ])

        TelegramService.shared.$authState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if state == .ready {
                    self?.view.endEditing(true)
                    Haptics.success()
                    self?.authDidSucceed()
                }
            }
            .store(in: &cancellables)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        let keyboardTop = view.keyboardLayoutGuide.layoutFrame.minY
        guard keyboardTop != lastKeyboardTop else { return }
        let isFirstLayout = lastKeyboardTop == nil
        lastKeyboardTop = keyboardTop
        guard !isFirstLayout else { return }

        let insets = scrollView.adjustedContentInset
        let bottomOffset = scrollView.contentSize.height + insets.bottom - scrollView.bounds.height
        let target = max(bottomOffset, -insets.top)
        if abs(target - scrollView.contentOffset.y) > 0.5 {
            scrollView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !hasAnimatedEntrance else { return }
        hasAnimatedEntrance = true

        let animatedViews: [UIView] = [titleLabel, subtitleLabel, contentStack, actionButton]
        for (index, animatedView) in animatedViews.enumerated() {
            animatedView.alpha = 0
            animatedView.transform = CGAffineTransform(translationX: 0, y: 16)
            UIView.animate(
                withDuration: 0.55,
                delay: 0.05 + 0.06 * Double(index),
                usingSpringWithDamping: 0.85,
                initialSpringVelocity: 0,
                options: [.allowUserInteraction]
            ) {
                animatedView.alpha = 1
                animatedView.transform = .identity
            }
        }
    }

    func setHero(_ hero: UIView) {
        heroContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }

        hero.setContentCompressionResistancePriority(UILayoutPriority(1), for: .vertical)
        heroContainer.addArrangedSubview(hero)
    }

    func authDidSucceed() {}

    func authDidFail() {}

    func showError(_ message: String) {
        errorLabel.text = message
        UIView.animate(withDuration: 0.25) { self.errorLabel.alpha = 1 }
        authDidFail()
    }

    func clearError() {
        guard errorLabel.alpha > 0 else { return }
        UIView.animate(withDuration: 0.25) { self.errorLabel.alpha = 0 }
    }

    func perform(_ action: @escaping () async throws -> Void, onError: ((Swift.Error) -> Void)? = nil) {
        guard !actionButton.isLoading else { return }
        clearError()
        actionButton.setLoading(true)
        Task { @MainActor in
            do {
                try await action()
            } catch {
                if !TelegramService.shared.authState.isAuthorized {
                    self.showError(error.telegramFriendlyMessage)
                    onError?(error)
                }
            }
            self.actionButton.setLoading(false)
        }
    }
}

extension Swift.Error {
    var telegramFriendlyMessage: String {
        (self as? TDLibKit.Error)?.friendlyMessage ?? localizedDescription
    }
}
