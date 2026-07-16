import XCTest
@testable import Shiiru

final class CountryCodesTests: XCTestCase {

    func testExplicitPatterns() {
        XCTAssertEqual(CountryCodes.format(nationalDigits: "5551234567", dialCode: "1"), "555 123 4567")
        XCTAssertEqual(CountryCodes.format(nationalDigits: "81981998", dialCode: "372"), "8198 1998")
        XCTAssertEqual(CountryCodes.format(nationalDigits: "81234567", dialCode: "65"), "8123 4567")
    }

    func testDynamicFallbackAdaptsToLength() {
        // +47 Norway (no explicit pattern): 8 digits group 4-4, not US 3-3-4.
        XCTAssertEqual(CountryCodes.format(nationalDigits: "92345678", dialCode: "47"), "9234 5678")
        // 7 digits: 3-4.
        XCTAssertEqual(CountryCodes.format(nationalDigits: "1234567", dialCode: "298"), "123 4567")
        // 9 digits: 3-3-3.
        XCTAssertEqual(CountryCodes.format(nationalDigits: "123456789", dialCode: "212"), "123 456 789")
    }

    func testOverflowContinuesInPairs() {
        XCTAssertEqual(
            CountryCodes.format(nationalDigits: "555123456789", dialCode: "1"),
            "555 123 4567 89"
        )
    }
}
