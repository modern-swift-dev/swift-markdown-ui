@testable import MarkdownUI
import SwiftUI
import XCTest

final class FontAndTextSpacingStyleTests: XCTestCase {
    func testFontFamilyReplacesTheFamilyOnly() {
        var attributes = attributesWithFontProperties(FontProperties(family: .system(), capsVariant: .smallCaps))
        FontFamily(.custom("Menlo"))._collectAttributes(in: &attributes)
        XCTAssertEqual(attributes.fontProperties?.family, .custom("Menlo"))
        XCTAssertEqual(attributes.fontProperties?.capsVariant, .smallCaps)

        FontFamily(.system(.serif))._collectAttributes(in: &attributes)
        XCTAssertEqual(attributes.fontProperties?.family, .system(.serif))
    }

    func testFontCapsVariantReplacesTheCapsVariantOnly() {
        var attributes = attributesWithFontProperties(FontProperties(family: .custom("Menlo")))
        for variant: FontProperties.CapsVariant in [.smallCaps, .lowercaseSmallCaps, .uppercaseSmallCaps, .normal] {
            FontCapsVariant(variant)._collectAttributes(in: &attributes)
            XCTAssertEqual(attributes.fontProperties?.capsVariant, variant)
        }
        XCTAssertEqual(attributes.fontProperties?.family, .custom("Menlo"))
    }

    func testFontDigitVariantReplacesTheDigitVariantOnly() {
        var attributes = attributesWithFontProperties(FontProperties(family: .custom("Menlo")))
        FontDigitVariant(.monospaced)._collectAttributes(in: &attributes)
        XCTAssertEqual(attributes.fontProperties?.digitVariant, .monospaced)
        FontDigitVariant(.normal)._collectAttributes(in: &attributes)
        XCTAssertEqual(attributes.fontProperties?.digitVariant, .normal)
        XCTAssertEqual(attributes.fontProperties?.family, .custom("Menlo"))
    }

    func testFontWidthReplacesTheWidthOnly() {
        var attributes = attributesWithFontProperties(FontProperties(digitVariant: .monospaced, width: .standard))
        FontWidth(.expanded)._collectAttributes(in: &attributes)
        XCTAssertEqual(attributes.fontProperties?.width, .expanded)
        FontWidth(.condensed)._collectAttributes(in: &attributes)
        XCTAssertEqual(attributes.fontProperties?.width, .condensed)
        XCTAssertEqual(attributes.fontProperties?.digitVariant, .monospaced)
    }

    func testFontStylesDoNothingWithoutFontProperties() {
        var attributes = AttributeContainer()
        FontFamily(.custom("Menlo"))._collectAttributes(in: &attributes)
        FontCapsVariant(.smallCaps)._collectAttributes(in: &attributes)
        FontDigitVariant(.monospaced)._collectAttributes(in: &attributes)
        FontWidth(.expanded)._collectAttributes(in: &attributes)
        XCTAssertEqual(attributes, AttributeContainer())
    }

    func testTextKerningSetsAndClearsTheKern() {
        var attributes = AttributeContainer()
        TextKerning(2.5)._collectAttributes(in: &attributes)
        XCTAssertEqual(attributes.kern, 2.5)
        XCTAssertEqual(attributes, AttributeContainer().kern(2.5))
        TextKerning(nil)._collectAttributes(in: &attributes)
        XCTAssertNil(attributes.kern)
    }

    func testTextTrackingSetsAndClearsTheTracking() {
        var attributes = AttributeContainer()
        TextTracking(1.5)._collectAttributes(in: &attributes)
        XCTAssertEqual(attributes.tracking, 1.5)
        XCTAssertEqual(attributes, AttributeContainer().tracking(1.5))
        TextTracking(nil)._collectAttributes(in: &attributes)
        XCTAssertNil(attributes.tracking)
    }

    func testTextStyleBuilderAppliesAllSpacingAndFontStylesInOrder() {
        @TextStyleBuilder func style() -> some TextStyle {
            FontFamily(.custom("Menlo"))
            FontCapsVariant(.smallCaps)
            FontDigitVariant(.monospaced)
            TextKerning(1)
            TextTracking(2)
            TextKerning(3)
        }
        var attributes = attributesWithFontProperties(FontProperties())
        style()._collectAttributes(in: &attributes)
        XCTAssertEqual(attributes.fontProperties?.family, .custom("Menlo"))
        XCTAssertEqual(attributes.fontProperties?.capsVariant, .smallCaps)
        XCTAssertEqual(attributes.fontProperties?.digitVariant, .monospaced)
        XCTAssertEqual(attributes.kern, 3)
        XCTAssertEqual(attributes.tracking, 2)
    }
}

private func attributesWithFontProperties(_ properties: FontProperties) -> AttributeContainer {
    var attributes = AttributeContainer()
    attributes.fontProperties = properties
    return attributes
}
