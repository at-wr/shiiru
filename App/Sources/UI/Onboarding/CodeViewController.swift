import UIKit
import TDLibKit

final class CodeViewController: OnboardingStepViewController {

    private let codeInfo: AuthenticationCodeInfo
    private let monkey = MonkeyView()
    private lazy var hero: UIView = sentToTelegramApp ? TGSHeroView(name: "IntroMessage") : monkey
    private var sentToTelegramApp: Bool {
        if case .authenticationCodeTypeTelegramMessage = codeInfo.type { return true }
        return false
    }
    private let codeView = CodeInputView()
    private let resendButton = UIButton(type: .system)
    private var resendTimer: Timer?
    private var secondsUntilResend = 0

    init(codeInfo: AuthenticationCodeInfo) {
        self.codeInfo = codeInfo
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { resendTimer?.invalidate() }

    override func viewDidLoad() {
        super.viewDidLoad()
        setHero(hero)
        titleLabel.text = "Enter Code"

        let phone = codeInfo.phoneNumber.isEmpty ? "" : "+\(codeInfo.phoneNumber)"
        let sentToApp: Bool
        switch codeInfo.type {
        case .authenticationCodeTypeTelegramMessage: sentToApp = true
        default: sentToApp = false
        }
        subtitleLabel.text = sentToApp
            ? "We've sent the code to the Telegram app\non your other device."
            : "We've sent an SMS with the code\nto \(phone)."

        codeView.length = codeLength
        codeView.onComplete = { [weak self] code in self?.submit(code) }
        codeView.onChange = { [weak self] count in
            guard let self else { return }
            self.clearError()
            if count == 0 {
                self.monkey.setState(.idle)
            } else {

                self.monkey.setState(.tracking(CGFloat(count) / CGFloat(self.codeLength)))
            }
        }
        contentStack.addArrangedSubview(codeView)

        resendButton.titleLabel?.font = Theme.footnoteFont()
        resendButton.addTarget(self, action: #selector(resend), for: .touchUpInside)
        contentStack.addArrangedSubview(resendButton)

        actionButton.title = "Continue"
        actionButton.onTap = { [weak self] in
            guard let self, self.codeView.code.count == self.codeLength else { return }
            self.submit(self.codeView.code)
        }

        startResendCountdown(codeInfo.timeout)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        codeView.activate()
    }

    override func authDidFail() {
        monkey.setState(.idle)
    }

    private var codeLength: Int {
        switch codeInfo.type {
        case .authenticationCodeTypeTelegramMessage(let info): return info.length
        case .authenticationCodeTypeSms(let info): return info.length
        case .authenticationCodeTypeCall(let info): return info.length
        case .authenticationCodeTypeFragment(let info): return info.length
        default: return 5
        }
    }

    private func submit(_ code: String) {
        perform {
            try await TelegramService.shared.submitCode(code)
        } onError: { [weak self] _ in
            self?.codeView.shake()
            self?.codeView.clear()
        }
    }

    @objc private func resend() {
        perform {
            try await TelegramService.shared.resendCode()
        }
        startResendCountdown(60)
    }

    private func startResendCountdown(_ seconds: Int) {
        resendTimer?.invalidate()
        secondsUntilResend = max(0, seconds)
        updateResendButton()
        guard secondsUntilResend > 0 else { return }
        resendTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.secondsUntilResend -= 1
            self.updateResendButton()
            if self.secondsUntilResend <= 0 { timer.invalidate() }
        }
    }

    private func updateResendButton() {
        if secondsUntilResend > 0 {
            resendButton.setTitle("Resend code in \(secondsUntilResend)s", for: .normal)
            resendButton.isEnabled = false
        } else {
            resendButton.setTitle("Resend Code", for: .normal)
            resendButton.isEnabled = true
        }
    }
}
