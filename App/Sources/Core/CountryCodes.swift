import Foundation
import PhoneNumberKit

struct Country: Equatable {
    let iso: String
    let dialCode: String

    var name: String {
        Locale.current.localizedString(forRegionCode: iso) ?? iso
    }

    var flag: String {
        iso.unicodeScalars.reduce(into: "") { result, scalar in
            if let flagScalar = Unicode.Scalar(0x1F1E6 + scalar.value - Unicode.Scalar("A").value) {
                result.unicodeScalars.append(flagScalar)
            }
        }
    }
}

/// Thin wrapper over PhoneNumberKit (libphonenumber): country metadata,
/// dial-code lookup, and as-you-type formatting. No hand-written rules.
enum CountryCodes {

    private static let kit = PhoneNumberKit()
    private static var formatters: [String: PartialFormatter] = [:]

    static let all: [Country] = kit.allCountries()
        .filter { $0 != "001" && Locale.current.localizedString(forRegionCode: $0) != nil }
        .compactMap { iso in
            kit.countryCode(for: iso).map { Country(iso: iso, dialCode: String($0)) }
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

    /// The device's region, falling back to the US.
    static var current: Country {
        let region = Locale.current.region?.identifier ?? "US"
        return all.first { $0.iso == region } ?? Country(iso: "US", dialCode: "1")
    }

    /// Longest-prefix match for a typed dial code; shared codes resolve to
    /// libphonenumber's main country (+1 → US, +7 → RU, …).
    static func country(forDialPrefix digits: String) -> Country? {
        guard !digits.isEmpty else { return nil }
        for length in stride(from: min(4, digits.count), through: 1, by: -1) {
            guard let code = UInt64(digits.prefix(length)) else { continue }
            if let main = kit.mainCountry(forCode: code) {
                return Country(iso: main, dialCode: String(code))
            }
        }
        return nil
    }

    /// Field placeholder: the country's example number in national format.
    static func placeholder(forCountry iso: String) -> String {
        kit.getFormattedExampleNumber(forCountry: iso, withFormat: .national, withPrefix: false)
            ?? "000 000 0000"
    }

    /// As-you-type national formatting.
    static func format(nationalDigits digits: String, dialCode: String) -> String {
        guard !digits.isEmpty else { return digits }
        let region = country(forDialPrefix: dialCode)?.iso ?? "US"
        let formatter: PartialFormatter
        if let cached = formatters[region] {
            formatter = cached
        } else {
            formatter = PartialFormatter(phoneNumberKit: kit, defaultRegion: region, withPrefix: false)
            formatters[region] = formatter
        }
        return formatter.formatPartial(digits)
    }

    /// Pretty international form for a full number ("+15551234567" or bare
    /// digits), used for display in Settings.
    static func formatInternational(_ number: String) -> String {
        let raw = number.hasPrefix("+") ? number : "+" + number
        guard let parsed = try? kit.parse(raw) else { return raw }
        return kit.format(parsed, toType: .international)
    }
}
