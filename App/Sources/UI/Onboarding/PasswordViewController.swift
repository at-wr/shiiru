import UIKit
import TDLibKit

final class PasswordViewController: OnboardingStepViewController, UITextFieldDelegate {

    private let waitState: AuthorizationStateWaitPassword
    private let monkey = MonkeyView()
    private let passwordField = InsetTextField()
    private let revealButton = UIButton(type: .system)
    private let forgotButton = UIButton(type: .system)

    init(waitState: AuthorizationStateWaitPassword) {
        self.waitState = waitState
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        setHero(monkey)
        titleLabel.text = "Two-Step Verification"
        subtitleLabel.text = "Your account is protected with\nan additional password."

        let hint = waitState.passwordHint
        passwordField.font = Theme.bodyFont()
        passwordField.isSecureTextEntry = true
        passwordField.textContentType = .password
        passwordField.placeholder = hint.isEmpty ? "Password" : "Hint: \(hint)"
        passwordField.textAlignment = .center
        passwordField.backgroundColor = Theme.cardBackground
        passwordField.layer.cornerRadius = Theme.cornerRadius
        passwordField.layer.cornerCurve = .continuous
        passwordField.returnKeyType = .go
        passwordField.delegate = self
        passwordField.addTarget(self, action: #selector(passwordChanged), for: .editingChanged)
        passwordField.translatesAutoresizingMaskIntoConstraints = false
        passwordField.heightAnchor.constraint(equalToConstant: 54).isActive = true

        revealButton.setImage(UIImage(systemName: "eye.slash"), for: .normal)
        revealButton.tintColor = .secondaryLabel
        revealButton.addTarget(self, action: #selector(toggleReveal), for: .touchUpInside)
        revealButton.translatesAutoresizingMaskIntoConstraints = false

        forgotButton.setTitle("Forgot password?", for: .normal)
        forgotButton.titleLabel?.font = Theme.footnoteFont()
        forgotButton.addTarget(self, action: #selector(forgotPassword), for: .touchUpInside)

        contentStack.addArrangedSubview(passwordField)
        contentStack.addArrangedSubview(forgotButton)
        passwordField.addSubview(revealButton)
        NSLayoutConstraint.activate([
            revealButton.trailingAnchor.constraint(equalTo: passwordField.trailingAnchor, constant: -14),
            revealButton.centerYAnchor.constraint(equalTo: passwordField.centerYAnchor),
            revealButton.widthAnchor.constraint(equalToConstant: 30),
            revealButton.heightAnchor.constraint(equalToConstant: 30),
        ])

        actionButton.title = "Continue"
        actionButton.isEnabled = false
        actionButton.onTap = { [weak self] in self?.submit() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        passwordField.becomeFirstResponder()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.passwordField.isSecureTextEntry else { return }
            self.monkey.setState(.eyesClosed)
        }
    }

    override func authDidSucceed() {
        monkey.setState(.idle)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        submit()
        return true
    }

    @objc private func passwordChanged() {
        clearError()
        actionButton.isEnabled = !(passwordField.text ?? "").isEmpty
    }

    @objc private func toggleReveal() {
        passwordField.isSecureTextEntry.toggle()
        let revealed = !passwordField.isSecureTextEntry
        revealButton.setImage(UIImage(systemName: revealed ? "eye" : "eye.slash"), for: .normal)
        monkey.setState(revealed ? .peeking : .eyesClosed)
        Haptics.tap()

        if let text = passwordField.text, revealed == false {
            passwordField.text = nil
            passwordField.insertText(text)
        }
    }

    private func submit() {
        guard let password = passwordField.text, !password.isEmpty else { return }
        perform {
            try await TelegramService.shared.submitPassword(password)
        }
    }

    @objc private func forgotPassword() {
        guard waitState.hasRecoveryEmailAddress else {
            let alert = UIAlertController(
                title: "No Recovery Email",
                message: "This account has no recovery email set up. You can reset the password from a logged-in Telegram app under Settings → Privacy and Security → Two-Step Verification.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }

        perform {
            try await TelegramService.shared.requestPasswordRecovery()
            await MainActor.run { self.promptForRecoveryCode() }
        }
    }

    private func promptForRecoveryCode() {
        let pattern = waitState.recoveryEmailAddressPattern
        let alert = UIAlertController(
            title: "Check Your Email",
            message: "We sent a recovery code to \(pattern.isEmpty ? "your recovery email" : pattern).",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "Recovery code"
            field.keyboardType = .numberPad
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Continue", style: .default) { [weak self, weak alert] _ in
            guard let code = alert?.textFields?.first?.text, !code.isEmpty else { return }
            self?.perform {
                try await TelegramService.shared.recoverPassword(code: code)
            }
        })
        present(alert, animated: true)
    }
}

final class InsetTextField: UITextField {
    private let insets = UIEdgeInsets(top: 0, left: 48, bottom: 0, right: 48)

    override func textRect(forBounds bounds: CGRect) -> CGRect {
        bounds.inset(by: insets)
    }

    override func editingRect(forBounds bounds: CGRect) -> CGRect {
        bounds.inset(by: insets)
    }

    override func placeholderRect(forBounds bounds: CGRect) -> CGRect {
        bounds.inset(by: insets)
    }
}
