import UIKit
import Combine

final class RootViewController: UIViewController {

    private enum Screen {
        case setup, loading, onboarding, main
    }

    private var currentScreen: Screen?
    private var current: UIViewController?
    private var onboardingNav: UINavigationController?
    private var cancellables = Set<AnyCancellable>()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        if PreviewMode.isActive {
            show(MainTabBarController(), as: .main, animated: false)
            return
        }
        if PreviewMode.isAuthPreview {
            if PreviewMode.authPreviewStep == "welcome" {
                show(UINavigationController(rootViewController: WelcomeViewController()), as: .onboarding, animated: false)
                return
            }
            let nav = UINavigationController(rootViewController: PhoneNumberViewController())
            switch PreviewMode.authPreviewStep {
            case "phone":
                break
            case "code":
                nav.pushViewController(CodeViewController(codeInfo: PreviewMode.sampleCodeInfo), animated: false)
            default:
                nav.pushViewController(CodeViewController(codeInfo: PreviewMode.sampleCodeInfo), animated: false)
                nav.pushViewController(PasswordViewController(waitState: PreviewMode.samplePasswordState), animated: false)
            }
            show(nav, as: .onboarding, animated: false)
            return
        }

        guard TelegramConfig.isConfigured else {
            show(SetupRequiredViewController(), as: .setup, animated: false)
            return
        }

        if DemoSession.isActive {
            show(MainTabBarController(), as: .main, animated: false)
        }
        NotificationCenter.default.addObserver(
            forName: DemoSession.changed, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if DemoSession.isActive {
                self.show(MainTabBarController(), as: .main, animated: true)
            } else {
                self.transition(to: TelegramService.shared.authState)
            }
        }

        TelegramService.shared.$authState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.transition(to: state)
            }
            .store(in: &cancellables)
    }

    private func transition(to state: TelegramService.AuthState) {

        guard !DemoSession.isActive else { return }
        switch state {
        case .starting, .loggingOut:
            onboardingNav = nil
            show(LoadingViewController(), as: .loading, animated: true)

        case .waitPhoneNumber:
            let nav = ensureOnboardingNav()

            if nav.viewControllers.contains(where: {
                $0 is CodeViewController || $0 is PasswordViewController || $0 is RegistrationViewController
            }) {
                nav.popToRootViewController(animated: true)
            }

        case .waitCode(let info):
            let nav = ensureOnboardingNav()
            if !(nav.topViewController is CodeViewController) {
                nav.pushViewController(CodeViewController(codeInfo: info), animated: true)
            }

        case .waitRegistration:
            let nav = ensureOnboardingNav()
            if !(nav.topViewController is RegistrationViewController) {
                nav.pushViewController(RegistrationViewController(), animated: true)
            }

        case .waitPassword(let waitState):
            let nav = ensureOnboardingNav()
            if !(nav.topViewController is PasswordViewController) {
                nav.pushViewController(PasswordViewController(waitState: waitState), animated: true)
            }

        case .ready:
            onboardingNav = nil
            show(MainTabBarController(), as: .main, animated: true)
        }
    }

    private func ensureOnboardingNav() -> UINavigationController {
        if let nav = onboardingNav, nav.parent === self { return nav }

        let phone = PhoneNumberViewController()
        let welcome = WelcomeViewController()
        let nav = UINavigationController(rootViewController: welcome)
        nav.navigationBar.tintColor = Theme.accent
        welcome.onContinue = { [weak nav] in
            nav?.pushViewController(phone, animated: true)
        }
        onboardingNav = nav
        show(nav, as: .onboarding, animated: true)
        return nav
    }

    private func show(_ child: UIViewController, as screen: Screen, animated: Bool) {
        guard screen != currentScreen else { return }
        currentScreen = screen
        let previous = current
        current = child

        addChild(child)
        child.view.frame = view.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(child.view)
        child.didMove(toParent: self)

        guard animated, let previous else {
            previous?.willMove(toParent: nil)
            previous?.view.removeFromSuperview()
            previous?.removeFromParent()
            return
        }
        child.view.alpha = 0
        child.view.transform = CGAffineTransform(scaleX: 1.03, y: 1.03)
        UIView.animate(
            withDuration: 0.45, delay: 0,
            usingSpringWithDamping: 0.9, initialSpringVelocity: 0
        ) {
            child.view.alpha = 1
            child.view.transform = .identity
            previous.view.alpha = 0
            previous.view.transform = CGAffineTransform(scaleX: 0.97, y: 0.97)
        } completion: { _ in
            previous.willMove(toParent: nil)
            previous.view.removeFromSuperview()
            previous.removeFromParent()
        }
    }
}

final class LoadingViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.startAnimating()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}
