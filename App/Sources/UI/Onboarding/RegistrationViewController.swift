import UIKit

final class RegistrationViewController: OnboardingStepViewController, UITextFieldDelegate {

    private let firstNameField = UITextField()
    private let lastNameField = UITextField()

    override func viewDidLoad() {
        super.viewDidLoad()
        setHero(AppIconMascotView())
        titleLabel.text = "Your Name"
        subtitleLabel.text = "This phone number is new to Telegram.\nEnter your name to create an account."

        for (field, placeholder) in [(firstNameField, "First Name"), (lastNameField, "Last Name (optional)")] {
            field.font = Theme.bodyFont()
            field.placeholder = placeholder
            field.textAlignment = .center
            field.backgroundColor = Theme.cardBackground
            field.layer.cornerRadius = Theme.cornerRadius
            field.layer.cornerCurve = .continuous
            field.autocapitalizationType = .words
            field.delegate = self
            field.addTarget(self, action: #selector(nameChanged), for: .editingChanged)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.heightAnchor.constraint(equalToConstant: 54).isActive = true
            contentStack.addArrangedSubview(field)
        }
        firstNameField.textContentType = .givenName
        firstNameField.returnKeyType = .next
        lastNameField.textContentType = .familyName
        lastNameField.returnKeyType = .go

        actionButton.title = "Create Account"
        actionButton.isEnabled = false
        actionButton.onTap = { [weak self] in self?.submit() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        firstNameField.becomeFirstResponder()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === firstNameField {
            lastNameField.becomeFirstResponder()
        } else {
            submit()
        }
        return true
    }

    @objc private func nameChanged() {
        clearError()
        actionButton.isEnabled = !(firstNameField.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func submit() {
        let first = (firstNameField.text ?? "").trimmingCharacters(in: .whitespaces)
        let last = (lastNameField.text ?? "").trimmingCharacters(in: .whitespaces)
        guard !first.isEmpty else { return }
        perform {
            try await TelegramService.shared.submitRegistration(firstName: first, lastName: last)
        }
    }
}
