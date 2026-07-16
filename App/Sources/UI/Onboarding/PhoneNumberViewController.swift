import UIKit

final class PhoneNumberViewController: OnboardingStepViewController, UITextFieldDelegate {

    private var country: Country = CountryCodes.current {
        didSet { applyCountry() }
    }

    private let countryButton = UIButton(type: .system)
    private let codeField = UITextField()
    private let numberField = UITextField()

    override func viewDidLoad() {
        super.viewDidLoad()
        setHero(TGSHeroView(name: "IntroPhone"))
        titleLabel.text = "Your Phone"
        subtitleLabel.text = "Please confirm your country code\nand enter your phone number."

        var countryConfig = UIButton.Configuration.plain()
        countryConfig.baseForegroundColor = .label
        countryConfig.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
        countryButton.configuration = countryConfig
        countryButton.contentHorizontalAlignment = .leading
        countryButton.backgroundColor = Theme.cardBackground
        countryButton.layer.cornerRadius = Theme.cornerRadius
        countryButton.layer.cornerCurve = .continuous
        countryButton.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        countryButton.addTarget(self, action: #selector(pickCountry), for: .touchUpInside)

        let chevron = UIImageView(image: UIImage(
            systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        ))
        chevron.tintColor = .tertiaryLabel
        chevron.translatesAutoresizingMaskIntoConstraints = false
        countryButton.addSubview(chevron)

        codeField.font = Theme.bodyFont()
        codeField.keyboardType = .phonePad
        codeField.textAlignment = .center
        codeField.delegate = self
        codeField.addTarget(self, action: #selector(codeChanged), for: .editingChanged)

        numberField.font = Theme.bodyFont()
        numberField.keyboardType = .phonePad
        numberField.textContentType = .telephoneNumber
        numberField.delegate = self
        numberField.addTarget(self, action: #selector(numberChanged), for: .editingChanged)

        let hairline = UIView()
        hairline.backgroundColor = .separator

        let fieldRow = UIView()
        fieldRow.backgroundColor = Theme.cardBackground
        fieldRow.layer.cornerRadius = Theme.cornerRadius
        fieldRow.layer.cornerCurve = .continuous
        fieldRow.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]

        for subview in [codeField, hairline, numberField] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            fieldRow.addSubview(subview)
        }

        let rowSeparator = UIView()
        rowSeparator.backgroundColor = .separator

        let group = UIStackView(arrangedSubviews: [countryButton, rowSeparator, fieldRow])
        group.axis = .vertical
        contentStack.addArrangedSubview(group)

        NSLayoutConstraint.activate([
            countryButton.heightAnchor.constraint(equalToConstant: 50),
            rowSeparator.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),
            fieldRow.heightAnchor.constraint(equalToConstant: 50),

            chevron.trailingAnchor.constraint(equalTo: countryButton.trailingAnchor, constant: -16),
            chevron.centerYAnchor.constraint(equalTo: countryButton.centerYAnchor),

            codeField.leadingAnchor.constraint(equalTo: fieldRow.leadingAnchor, constant: 16),
            codeField.widthAnchor.constraint(equalToConstant: 64),
            codeField.topAnchor.constraint(equalTo: fieldRow.topAnchor),
            codeField.bottomAnchor.constraint(equalTo: fieldRow.bottomAnchor),

            hairline.leadingAnchor.constraint(equalTo: codeField.trailingAnchor, constant: 12),
            hairline.widthAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),
            hairline.topAnchor.constraint(equalTo: fieldRow.topAnchor, constant: 10),
            hairline.bottomAnchor.constraint(equalTo: fieldRow.bottomAnchor, constant: -10),

            numberField.leadingAnchor.constraint(equalTo: hairline.trailingAnchor, constant: 12),
            numberField.trailingAnchor.constraint(equalTo: fieldRow.trailingAnchor, constant: -16),
            numberField.topAnchor.constraint(equalTo: fieldRow.topAnchor),
            numberField.bottomAnchor.constraint(equalTo: fieldRow.bottomAnchor),
        ])

        actionButton.title = "Continue"
        actionButton.isEnabled = false
        actionButton.onTap = { [weak self] in self?.confirmAndSubmit() }

        applyCountry()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        numberField.becomeFirstResponder()
    }

    private func applyCountry() {
        countryButton.configuration?.title = "\(country.flag)  \(country.name)"
        codeField.text = "+\(country.dialCode)"
        numberField.placeholder = CountryCodes
            .numberPattern(forDialCode: country.dialCode)
            .replacingOccurrences(of: "X", with: "0")
        reformatNumber()
    }

    @objc private func pickCountry() {
        Haptics.tap()
        let picker = CountryPickerViewController()
        picker.onSelect = { [weak self] selected in
            self?.country = selected
            self?.numberField.becomeFirstResponder()
        }
        navigationController?.pushViewController(picker, animated: true)
    }

    @objc private func codeChanged() {
        clearError()
        let digits = (codeField.text ?? "").filter(\.isNumber)
        codeField.text = "+" + digits
        if let match = CountryCodes.country(forDialPrefix: digits), match.dialCode == digits {
            country = match
            numberField.becomeFirstResponder()
        } else if let match = CountryCodes.country(forDialPrefix: digits) {
            countryButton.configuration?.title = "\(match.flag)  \(match.name)"
        } else {
            countryButton.configuration?.title = digits.isEmpty ? "Choose a Country" : "Invalid Country Code"
        }
        updateContinueState()
    }

    @objc private func numberChanged() {
        clearError()
        reformatNumber()
        updateContinueState()
    }

    private func reformatNumber() {
        let digits = (numberField.text ?? "").filter(\.isNumber)
        numberField.text = CountryCodes.format(nationalDigits: digits, dialCode: country.dialCode)
    }

    private func updateContinueState() {
        actionButton.isEnabled = nationalDigits.count >= 5 && !dialDigits.isEmpty
    }

    private var nationalDigits: String { (numberField.text ?? "").filter(\.isNumber) }
    private var dialDigits: String { (codeField.text ?? "").filter(\.isNumber) }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        confirmAndSubmit()
        return true
    }

    private func confirmAndSubmit() {
        guard actionButton.isEnabled else { return }
        let pretty = "+\(dialDigits) \(CountryCodes.format(nationalDigits: nationalDigits, dialCode: dialDigits))"
        let alert = UIAlertController(
            title: pretty,
            message: "Is this the correct number?",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Edit", style: .cancel))
        alert.addAction(UIAlertAction(title: "Continue", style: .default) { [weak self] _ in
            self?.submit()
        })
        present(alert, animated: true)
    }

    private func submit() {

        if dialDigits + nationalDigits == DemoSession.phoneDigits {
            perform { await DemoSession.activate() }
            return
        }
        let number = "+" + dialDigits + nationalDigits
        perform {
            try await TelegramService.shared.submitPhoneNumber(number)
        }
    }
}
