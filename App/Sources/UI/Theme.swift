import UIKit

enum Theme {

    static let accent = UIColor(dynamicLight: UIColor(hex: 0x2AABEE), dark: UIColor(hex: 0x3EB5F1))
    static let sealRed = UIColor(hex: 0xE0452F)

    static let background = UIColor.systemGroupedBackground
    static let cardBackground = UIColor.secondarySystemGroupedBackground

    static let buttonHeight: CGFloat = 52
    static let cornerRadius: CGFloat = 12

    static func largeTitleFont() -> UIFont {
        .systemFont(ofSize: 28, weight: .bold)
    }

    static func titleFont() -> UIFont {
        .systemFont(ofSize: 20, weight: .semibold)
    }

    static func bodyFont() -> UIFont {
        .systemFont(ofSize: 17)
    }

    static func footnoteFont() -> UIFont {
        .systemFont(ofSize: 14)
    }

    static func apply() {
        UIView.appearance().tintColor = accent
        UISwitch.appearance().onTintColor = accent
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    convenience init(dynamicLight light: UIColor, dark: UIColor) {
        self.init { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        }
    }
}
