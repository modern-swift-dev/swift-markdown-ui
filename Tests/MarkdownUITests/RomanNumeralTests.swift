@testable import MarkdownUI
import XCTest

final class RomanNumeralTests: XCTestCase {
    func testRomanNumeralsUseSubtractiveNotation() {
        let expected: [(Int, String)] = [
            (1, "I"), (2, "II"), (3, "III"), (4, "IV"), (5, "V"), (6, "VI"), (9, "IX"), (10, "X"),
            (14, "XIV"), (19, "XIX"), (40, "XL"), (49, "XLIX"), (90, "XC"), (99, "XCIX"), (400, "CD"),
            (444, "CDXLIV"), (500, "D"), (900, "CM"), (1000, "M"), (1994, "MCMXCIV"), (2024, "MMXXIV"),
            (3999, "MMMCMXCIX")
        ]
        for (number, numeral) in expected {
            XCTAssertEqual(number.roman, numeral, "\(number)")
        }
    }

    func testNumbersOutsideTheRomanRangeFallBackToDecimal() {
        for number in [-12, -1, 0, 4000, 12345] {
            XCTAssertEqual(number.roman, "\(number)")
        }
    }
}
