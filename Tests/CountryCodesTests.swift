import XCTest
@testable import Shiiru

final class CountryCodesTests: XCTestCase {

    private func digits(_ s: String) -> String { s.filter(\.isNumber) }

    func testFormattingPreservesDigitsAndGroups() {
        for (number, dial) in [("5551234567", "1"), ("81981998", "372"), ("92345678", "47")] {
            let formatted = CountryCodes.format(nationalDigits: number, dialCode: dial)
            XCTAssertEqual(digits(formatted), number, "digits must survive formatting")
            XCTAssertTrue(formatted.contains(" "), "\(dial) number should be grouped: \(formatted)")
        }
    }

    func testEstonianNumberIsNotUSGrouped() {
        let formatted = CountryCodes.format(nationalDigits: "81981998", dialCode: "372")
        XCTAssertNotEqual(formatted, "819 819 98")
    }
}
