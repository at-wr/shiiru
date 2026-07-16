import UIKit

final class CodeInputView: UIView, UITextFieldDelegate {

    var length: Int = 5 {
        didSet { rebuildBoxes() }
    }

    var onComplete: ((String) -> Void)?

    var onChange: ((Int) -> Void)?

    private let textField = UITextField()
    private let stack = UIStackView()
    private var boxes: [DigitBox] = []

    override init(frame: CGRect) {
        super.init(frame: frame)

        stack.axis = .horizontal
        stack.spacing = 10
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        textField.keyboardType = .numberPad
        textField.textContentType = .oneTimeCode
        textField.isHidden = true
        textField.delegate = self
        textField.addTarget(self, action: #selector(textChanged), for: .editingChanged)
        addSubview(textField)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.heightAnchor.constraint(equalToConstant: 54),
        ])

        rebuildBoxes()
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(activate)))
    }

    required init?(coder: NSCoder) { fatalError() }

    private func rebuildBoxes() {
        boxes.forEach { $0.removeFromSuperview() }
        boxes = (0..<length).map { _ in DigitBox() }
        boxes.forEach { box in
            box.widthAnchor.constraint(equalToConstant: 44).isActive = true
            stack.addArrangedSubview(box)
        }
        refresh()
    }

    var code: String { textField.text ?? "" }

    @objc func activate() {
        textField.becomeFirstResponder()
    }

    func clear() {
        textField.text = ""
        refresh()
    }

    func shake() {
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, -12, 10, -8, 6, -4, 0]
        animation.duration = 0.45
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "shake")
        Haptics.error()
    }

    @objc private func textChanged() {
        var text = (textField.text ?? "").filter(\.isNumber)
        if text.count > length { text = String(text.prefix(length)) }
        textField.text = text
        refresh()
        onChange?(text.count)
        if text.count == length {
            onComplete?(text)
        }
    }

    private func refresh() {
        let text = textField.text ?? ""
        for (index, box) in boxes.enumerated() {
            let character = index < text.count
                ? String(text[text.index(text.startIndex, offsetBy: index)])
                : ""
            box.setDigit(character, isCursor: index == text.count)
        }
    }

    private final class DigitBox: UIView {
        private let label = UILabel()

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .secondarySystemFill
            layer.cornerRadius = 10
            layer.cornerCurve = .continuous
            layer.borderWidth = 1.5
            layer.borderColor = UIColor.clear.cgColor

            label.font = .monospacedDigitSystemFont(ofSize: 24, weight: .semibold)
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        required init?(coder: NSCoder) { fatalError() }

        func setDigit(_ digit: String, isCursor: Bool) {
            if label.text != digit, !digit.isEmpty {
                label.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
                UIView.animate(
                    withDuration: 0.35, delay: 0,
                    usingSpringWithDamping: 0.6, initialSpringVelocity: 0
                ) {
                    self.label.transform = .identity
                }
            }
            label.text = digit
            UIView.animate(withDuration: 0.2) {
                self.layer.borderColor = isCursor ? Theme.accent.cgColor : UIColor.clear.cgColor
            }
        }
    }
}
